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

      # IO-like reader that spans every gzip member in a file. Zlib::GzipReader
      # stops at the end of the first member, so a file with concatenated
      # members (`gzip -c a b`, pigz output) would silently lose everything
      # after the first member.
      class GzipMembers
        CHUNK = 64 * 1024

        def initialize(path)
          @io = File.open(path, "rb")
          @buffer = +"".b
          @pending = nil
          @inflater = nil
          @fed = 0
          @inflated = 0
          @members = 0
          @produced = false
          @done = false
        end

        def read(length = nil)
          fill while !@done && (length.nil? || @buffer.bytesize < length)
          return nil if @buffer.empty?

          return @buffer.slice!(0, length) if length

          data = @buffer
          @buffer = +"".b
          data
        end

        def getc
          read(1)
        end

        def eof?
          @buffer.empty? && @done
        end

        def pos
          @inflated - @buffer.bytesize
        end

        def close
          @io.close unless @io.closed?
        end

        private

        def fill
          chunk = next_chunk
          if chunk.nil? || chunk.empty?
            raise gzip_error("unexpected end of gzip stream") if @inflater
            raise gzip_error("not in gzip format") if @members.zero?

            @done = true
            return
          end

          @inflater ||= Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
          before = @fed
          @fed += chunk.bytesize
          begin
            data = @inflater.inflate(chunk)
          rescue Zlib::Error => e
            # A member that breaks after producing data is corrupt; bytes that
            # do not start a member are trailing data behind the last member.
            raise gzip_error(e.message) if @produced || @members.zero?

            @done = true
            return
          end

          unless data.empty?
            @produced = true
            @inflated += data.bytesize
            @buffer << data
          end

          return unless @inflater.finished?

          used = @inflater.total_in - before
          leftover = chunk.bytesize - used
          @pending = leftover.positive? ? chunk.byteslice(chunk.bytesize - leftover, leftover) : nil
          @inflater = nil
          @fed = 0
          @produced = false
          @members += 1
        end

        def next_chunk
          if @pending
            chunk = @pending
            @pending = nil
            return chunk
          end

          @io.read(CHUNK)
        end

        def gzip_error(message)
          Zlib::GzipFile::Error.new(message)
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
          File.open(path, "rb") { |io| read_tar(io, &block) }
        when "tgz"
          reader = GzipMembers.new(path)
          begin
            read_tar(reader, &block)
          ensure
            reader.close
          end
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
      rescue Zip::Error, Zlib::GzipFile::Error, Gem::Package::TarInvalidError,
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

      def read_tar(io)
        pending_name = nil
        pending_size = nil
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            type = entry.header.typeflag
            if type == "L"
              # GNU long name: the path of the entry that follows.
              pending_name = entry.read.split("\0", 2).first
              next
            elsif type == "x" || type == "g"
              # pax extended header: metadata for the entry that follows.
              records = pax_records(entry.read)
              pending_name = records["path"] || pending_name
              pending_size = records["size"]&.to_i || pending_size
              next
            end

            name = (pending_name || entry.full_name).to_s.dup.force_encoding(Encoding::UTF_8)
            declared_size = pending_size
            pending_name = nil
            pending_size = nil
            if type == "5"
              yield Entry.new(name: name, mode: entry.header.mode, mtime: time_from(entry.header.mtime),
                              size: 0, directory: true)
            elsif type == "0" || type == "\0"
              if declared_size && declared_size != entry.size
                raise tar_size_error(name, declared_size)
              end

              yield Entry.new(name: name, mode: entry.header.mode, mtime: time_from(entry.header.mtime),
                              size: entry.size, directory: false, io: entry)
            else
              raise unsafe_error("non-regular TAR entry #{name.inspect} (type #{type.inspect})")
            end
          end
        end
      end

      # pax extended headers hold "key=value" records, each prefixed with its
      # byte length ("150 path=...").
      def pax_records(content)
        records = {}
        text = content.to_s.b
        offset = 0
        while offset < text.bytesize
          space = text.index(" ", offset)
          break unless space

          length = text.byteslice(offset, space - offset).to_i
          break if length <= 0

          record = text.byteslice(space + 1, length - (space - offset) - 2)
          break if record.nil?

          key, separator, value = record.partition("=")
          records[key] = value unless separator.empty?
          offset += length
        end
        records
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

      def tar_size_error(name, size)
        Cvt::Errors.build(
          "conversion_failed",
          "TAR entry #{name.to_s.delete("\n").inspect} declares #{size} bytes that its header cannot hold",
          hint: "Split the entry into smaller files before converting."
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
