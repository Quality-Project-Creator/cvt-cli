# frozen_string_literal: true

# Reference: rubyzip (BSD-2-Clause) https://github.com/rubyzip/rubyzip
# Reference: RubyGems (Ruby License) https://github.com/rubygems/rubygems
# Reference: zlib (zlib license) https://zlib.net

require "fileutils"
require "rubygems/package"
require "zlib"
require "zip"

require_relative "../../errors"

module Cvt
  module Adapters
    # Repacks zip/tar/tgz members without extracting to a directory. Entry
    # streams are copied from reader to writer in 64 KiB chunks so archives
    # larger than memory are still handled and the uncompressed budget can be
    # enforced while repacking.
    module Archive
      CONTAINERS = %w[zip tar tgz].freeze
      STREAMS = %w[gz xz bz2].freeze
      DEFAULT_MAX_SIZE = 1024**3
      CHUNK_SIZE = 64 * 1024
      DEFAULT_FILE_MODE = 0o644
      DEFAULT_DIR_MODE = 0o755

      Entry = Struct.new(:name, :mode, :mtime, :size, :directory, :io, keyword_init: true)

      # Streaming reader for gzip files that may hold several members.
      # Zlib::GzipReader stops after the first member, so a concatenated
      # archive would silently lose everything after it.
      class GzipStream
        CHUNK_SIZE = 64 * 1024

        def initialize(io)
          @io = io
          @input = +"".b
          @pending = +"".b
          @inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
          @pos = 0
          @done = false
          @member_done = false
        end

        def pos
          @pos
        end

        def eof?
          @done && @pending.empty?
        end

        def read(maxlen = nil)
          return read_all if maxlen.nil?

          return "" if maxlen.to_i.zero?

          while @pending.bytesize < maxlen && !@done
            pump
          end
          out = @pending.slice!(0, maxlen)
          @pos += out.bytesize
          out.empty? && eof? ? nil : out
        end

        def getc
          read(1)&.byteslice(0, 1)
        end

        def each_chunk
          while (chunk = read(CHUNK_SIZE))
            break if chunk.empty?

            yield chunk
          end
        end

        def close
          @inflater.close
        end

        private

        def read_all
          out = +"".b
          until @done
            pump
            out << @pending
            @pending = +"".b
          end
          @pos += out.bytesize
          out
        end

        # Decompresses one member step. @member_done tracks whether the last
        # member ended cleanly, so a truncated stream is reported instead of
        # being passed off as a complete file.
        def pump
          loop do
            if @input.empty?
              chunk = @io.read(CHUNK_SIZE)
              if chunk.nil?
                finish
                return
              end
              @input << chunk
            end

            before = @inflater.total_in
            data = @inflater.inflate(@input)
            consumed = @inflater.total_in - before
            @input = @input.byteslice(consumed, @input.bytesize - consumed) || +"".b
            @pending << data unless data.empty?

            if @inflater.finished?
              @inflater.close
              @inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
              @member_done = true
            else
              @member_done = false
            end

            return unless @pending.empty?
            next unless data.empty? && consumed.zero?

            chunk = @io.read(CHUNK_SIZE)
            if chunk.nil?
              finish
              return
            end
            @input << chunk
          end
        end

        def finish
          @done = true
          return if @member_done

          raise Zlib::GzipFile::Error, "unexpected end of file"
        end
      end

      # Gem::Package::TarWriter stamps entries with SOURCE_DATE_EPOCH. This
      # subclass keeps the reader/writer pairing but accepts the source mtime.
      class MtimeTarWriter < Gem::Package::TarWriter
        def add_file_simple(name, mode, size, mtime = nil)
          check_closed

          name, prefix = split_name(name)
          header = Gem::Package::TarHeader.new(
            name: name, mode: mode, size: size, prefix: prefix,
            mtime: (mtime || Gem.source_date_epoch).to_i
          ).to_s
          @io.write header

          stream = Gem::Package::TarWriter::BoundedStream.new(@io, size)
          yield stream if block_given?
          @io.write("\0" * (size - stream.written))
          @io.write("\0" * ((512 - (size % 512)) % 512))

          self
        end

        def mkdir(name, mode, mtime = nil)
          check_closed

          name, prefix = split_name(name)
          @io.write Gem::Package::TarHeader.new(
            name: name, mode: mode, typeflag: "5", size: 0, prefix: prefix,
            mtime: (mtime || Gem.source_date_epoch).to_i
          )

          self
        end
      end

      module_function

      def repack(input, output, from, to, options = {}, warnings = [])
        max_size = max_size(options)
        copied = 0

        with_writer(output, to) do |write|
          each_entry(input, from) do |entry|
            validate_name!(entry.name)
            if entry.directory
              write.call(entry, nil)
            else
              budget = remaining_budget(max_size, copied)
              if budget && entry.size > budget
                raise max_size_error(max_size)
              end
              written = write.call(entry, budget)
              copied += written
              raise max_size_error(max_size) if max_size.positive? && copied > max_size
            end
          end
        end

        warnings << {
          "code" => "archive_metadata_loss",
          "message" => "Entry ownership and extended attributes may not survive repacking " \
                       "from #{from} to #{to}."
        }
        warnings
      end

      def each_entry(path, format, &block)
        case format.to_s
        when "zip"
          Zip::File.open(path) do |zip|
            zip.each do |entry|
              check_zip_entry!(entry)
              if entry.directory?
                block.call(Entry.new(name: entry.name, mode: mode_for(entry), mtime: entry.mtime,
                                     size: 0, directory: true))
              else
                stream = entry.get_input_stream
                begin
                  block.call(Entry.new(name: entry.name, mode: mode_for(entry), mtime: entry.mtime,
                                       size: entry.size, directory: false, io: stream))
                ensure
                  stream.close
                end
              end
            end
          end
        when "tar"
          File.open(path, "rb") { |io| read_tar(io, path, "tar", &block) }
        when "tgz"
          File.open(path, "rb") { |io| read_tar(GzipStream.new(io), path, "tgz", &block) }
        else
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "native_archive cannot read #{format} as a container",
            hint: "Use zip, tar, or tgz as the container format."
          )
        end
      rescue Cvt::Error
        raise
      rescue Zip::EntryNameError => e
        raise unsafe_error(e.message)
      rescue Zip::Error, Zlib::Error, Gem::Package::TarInvalidError,
             Gem::Package::FormatError, Errno::ENOENT => e
        raise corrupt_error("#{format} archive", e)
      end

      def with_writer(path, format)
        case format.to_s
        when "zip"
          Zip::File.open(path, create: true) do |zip|
            yield lambda { |entry, _budget| write_zip(zip, entry) }
          end
        when "tar"
          File.open(path, "wb") do |io|
            tar = MtimeTarWriter.new(io)
            begin
              yield lambda { |entry, budget| write_tar(tar, entry, budget) }
            ensure
              tar.close
            end
          end
        when "tgz"
          Zlib::GzipWriter.open(path) do |gz|
            tar = MtimeTarWriter.new(gz)
            begin
              yield lambda { |entry, budget| write_tar(tar, entry, budget) }
            ensure
              tar.close
            end
          end
        else
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "native_archive cannot write #{format} as a container",
            hint: "Use zip, tar, or tgz as the container format."
          )
        end
      end

      def read_tar(io, path, format)
        each_tar_entry(io) do |name, type, entry|
          case type
          when "5"
            yield Entry.new(name: name, mode: entry.header.mode, mtime: time_from(entry.header.mtime),
                            size: 0, directory: true)
          when "0", "\0"
            yield Entry.new(name: name, mode: entry.header.mode, mtime: time_from(entry.header.mtime),
                            size: entry.size, directory: false, io: entry)
          when "1"
            hardlink_entry(path, format, name, entry) do |size, content|
              yield Entry.new(name: name, mode: entry.header.mode, mtime: time_from(entry.header.mtime),
                              size: size, directory: false, io: content)
            end
          else
            raise unsafe_error("non-regular TAR entry #{name.inspect} (type #{type.inspect})")
          end
        end
      end

      # Walks the TAR entries and resolves the name overrides GNU and pax
      # headers carry: a "L" entry names the next file, an "x" entry holds
      # pax records whose "path" key names the next file.
      def each_tar_entry(io)
        long_name = nil
        pax_path = nil
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            type = entry.header.typeflag
            case type
            when "L"
              long_name = entry.read.to_s.split("\0").first.to_s.force_encoding(Encoding::UTF_8)
              next
            when "x"
              path = parse_pax(entry.read)["path"]
              pax_path = path.to_s.force_encoding(Encoding::UTF_8) unless path.nil?
              next
            when "g"
              next
            end
            name = pax_path || long_name || entry.full_name
            pax_path = nil
            long_name = nil
            yield name, type, entry
          end
        end
      end

      def parse_pax(data)
        records = {}
        data.to_s.each_line do |line|
          match = /\A\d+ (.+)\z/.match(line.chomp("\n"))
          next unless match

          key, _, value = match[1].partition("=")
          records[key] = value
        end
        records
      end

      # A hard link carries no bytes of its own: they live in the entry it
      # points at. The target is looked up in a second pass so the copy keeps
      # every path instead of dropping the link.
      def hardlink_entry(path, format, name, entry)
        target = entry.header.linkname.to_s
        found = false
        reopen_tar(path, format) do |io|
          each_tar_entry(io) do |target_name, target_type, target_entry|
            next unless target_name == target && (target_type == "0" || target_type == "\0")

            found = true
            yield target_entry.size, target_entry
            break
          end
        end
        return if found

        raise Cvt::Errors.build(
          "conversion_failed",
          "TAR hard link #{name.inspect} points at a missing entry #{target.inspect}",
          hint: "Repack the archive without hard links before converting."
        )
      end

      def reopen_tar(path, format)
        File.open(path, "rb") do |io|
          yield(format.to_s == "tgz" ? GzipStream.new(io) : io)
        end
      end

      def write_zip(zip, entry)
        if entry.directory
          zip.mkdir(entry.name, safe_mode(entry.mode, DEFAULT_DIR_MODE))
          return 0
        end

        bytes = 0
        zip.get_output_stream(entry.name, permissions: safe_mode(entry.mode, DEFAULT_FILE_MODE),
                                              time: entry.mtime || Time.now) do |out|
          bytes = copy_stream(entry.io, out)
        end
        bytes
      end

      def write_tar(tar, entry, budget)
        if entry.directory
          tar.mkdir(entry.name, safe_mode(entry.mode, DEFAULT_DIR_MODE), entry.mtime)
          return 0
        end

        written = 0
        tar.add_file_simple(entry.name, safe_mode(entry.mode, DEFAULT_FILE_MODE), entry.size,
                            entry.mtime) do |out|
          written = copy_stream(entry.io, out, budget)
        end
        written
      end

      def copy_stream(source, destination, limit = nil)
        written = 0
        while (chunk = source.read(CHUNK_SIZE))
          break if chunk.empty?

          written += chunk.bytesize
          raise max_size_error(limit) if limit && written > limit

          destination.write(chunk)
        end
        written
      end

      def check_zip_entry!(entry)
        if entry.encrypted?
          raise Cvt::Errors.build(
            "conversion_failed",
            "ZIP archive is encrypted",
            hint: "Decrypt the archive first (for example with 7z) and retry; CVT does not accept passwords."
          )
        end
        return if entry.directory? || entry.ftype == :file

        raise unsafe_error("non-regular ZIP entry #{entry.name.inspect} (#{entry.ftype})")
      end

      def validate_name!(name)
        raw = name.to_s
        raise unsafe_error("empty entry name") if raw.empty?

        if raw.start_with?("/", "\\") || raw.match?(/\A[A-Za-z]:/)
          raise unsafe_error("absolute path #{raw.inspect}")
        end
        if raw.split(%r{[/\\]}).include?("..")
          raise unsafe_error("parent-directory reference #{raw.inspect}")
        end
      end

      def unsafe_error(reason)
        Cvt::Errors.build(
          "unsafe_archive",
          "Archive contains an unsafe entry: #{reason}".delete("\n"),
          hint: "Remove absolute paths, '..' references, symlinks, and device files before converting."
        )
      end

      def corrupt_error(label, error)
        Cvt::Errors.build(
          "conversion_failed",
          "Unable to read #{label}: #{error.message.to_s.lines.first.to_s.strip}",
          hint: "Check that the input file is a valid #{label.split.first} archive."
        )
      end

      def max_size_error(_limit = nil)
        Cvt::Errors.build(
          "conversion_failed",
          "Uncompressed archive data exceeds the --max-size limit",
          hint: "Raise --max-size or convert a smaller archive."
        )
      end

      def max_size(options)
        value = options["max_size"]
        return DEFAULT_MAX_SIZE if value.nil? || value.to_s.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        DEFAULT_MAX_SIZE
      end

      def remaining_budget(max_size, copied)
        return nil unless max_size.positive?

        max_size - copied
      end

      def mode_for(entry)
        perms = entry.unix_perms
        perms.to_i & 0o7777
      end

      def safe_mode(mode, fallback)
        value = mode.to_i
        value.zero? ? fallback : value
      end

      def time_from(value)
        return nil if value.nil?

        value.is_a?(Time) ? value : Time.at(Integer(value))
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
