# frozen_string_literal: true

# Reference: XZ Utils (0BSD) https://tukaani.org/xz
# Reference: bzip2 (bzip2 license) https://sourceware.org/bzip2
# Reference: 7-Zip (LGPL-2.1+) https://www.7-zip.org
# Reference: zlib (zlib license) https://zlib.net

require "fileutils"
require "tmpdir"
require "zlib"

require_relative "../../errors"
require_relative "../../shell"
require_relative "containers"
require_relative "tools"

module Cvt
  module Adapters
    # Single-stream gz/xz/bz2 recompression. Gzip is handled in-process with
    # zlib; xz and bzip2 use their binaries and fall back to 7-Zip when the
    # native tool is missing. The decompressed payload lives in a temporary
    # directory, never next to the user's input.
    module Streams
      CHUNK_SIZE = 64 * 1024
      FORMATS = Archive::STREAMS
      EXTENSIONS = { "xz" => ".xz", "bz2" => ".bz2" }.freeze
      SEVEN_ZIP_FORMATS = { "xz" => "xz", "bz2" => "bzip2" }.freeze

      module_function

      def recompress(input, output, from, to, options = {}, _warnings = [])
        max_size = Archive.max_size(options)
        timeout = options["timeout"].to_i

        Dir.mktmpdir("cvt-stream-") do |dir|
          payload = decompress(input, from, dir, timeout, max_size)
          enforce_size(payload, max_size)
          compress(payload, output, to, dir, timeout)
        end
      rescue Cvt::Error
        raise
      rescue Zlib::Error => e
        raise Cvt::Errors.build(
          "conversion_failed",
          "GZIP data is corrupt: #{e.message.to_s.lines.first.to_s.strip}",
          hint: "Check that the input file is a complete gzip stream."
        )
      end

      def decompress(input, from, dir, timeout, max_size = 0)
        payload = File.join(dir, "payload")
        case from.to_s
        when "gz"
          written = 0
          File.open(payload, "wb") do |out|
            File.open(input, "rb") do |io|
              Archive::GzipStream.new(io).each_chunk do |chunk|
                written += chunk.bytesize
                raise size_error if max_size.positive? && written > max_size

                out.write(chunk)
              end
            end
          end
          payload
        when "xz", "bz2"
          selection = Archive.select_tool(from)
          raise tool_error(from) unless selection

          copy_path = File.join(dir, "source#{EXTENSIONS.fetch(from.to_s)}")
          FileUtils.cp(input, copy_path)
          if selection.seven_zip?
            Cvt::Shell.run!(seven_extract_argv(selection, copy_path, dir), timeout: timeout)
          else
            Cvt::Shell.run!([selection.path, "-d", "-f", "-k", copy_path], timeout: timeout)
          end
          extracted = File.join(dir, "source")
          unless File.file?(extracted)
            raise Cvt::Errors.build(
              "conversion_failed",
              "Unable to decompress #{from} stream",
              hint: "Check that the input file is a valid #{from} file."
            )
          end
          FileUtils.mv(extracted, payload, force: true)
          payload
        else
          raise unsupported_error(from, "decompress")
        end
      end

      def compress(payload, output, to, dir, timeout)
        case to.to_s
        when "gz"
          Zlib::GzipWriter.open(output) do |gz|
            File.open(payload, "rb") { |io| copy(io, gz) }
          end
        when "xz", "bz2"
          selection = Archive.select_tool(to)
          raise tool_error(to) unless selection

          result = if selection.seven_zip?
                     result_name = "out#{EXTENSIONS.fetch(to.to_s)}"
                     Cvt::Shell.run!(
                       [selection.path, "a", "-t#{SEVEN_ZIP_FORMATS.fetch(to.to_s)}", "-y",
                        result_name, File.basename(payload)],
                       timeout: timeout, chdir: dir
                     )
                     File.join(dir, result_name)
                   else
                     Cvt::Shell.run!([selection.path, "-z", "-f", "-k", payload], timeout: timeout)
                     "#{payload}#{EXTENSIONS.fetch(to.to_s)}"
                   end
          unless File.file?(result)
            raise Cvt::Errors.build(
              "conversion_failed",
              "Unable to compress data as #{to}",
              hint: "Check that the #{to} compressor can write to the output directory."
            )
          end
          FileUtils.mv(result, output, force: true)
        else
          raise unsupported_error(to, "compress")
        end
      end

      def enforce_size(payload, max_size)
        return unless max_size.positive?
        return unless File.size(payload) > max_size

        raise size_error
      end

      def size_error
        Cvt::Errors.build(
          "conversion_failed",
          "Uncompressed archive data exceeds the --max-size limit",
          hint: "Raise --max-size or convert a smaller file."
        )
      end

      def copy(source, destination)
        while (chunk = source.read(CHUNK_SIZE))
          break if chunk.empty?

          destination.write(chunk)
        end
      end

      def seven_extract_argv(selection, path, dir)
        [selection.path, "x", "-y", "-o#{dir}", path]
      end

      def unsupported_error(format, action)
        Cvt::Errors.build(
          "unsupported_conversion",
          "native_archive cannot #{action} #{format} as a single stream",
          hint: "Use gz, xz, or bz2 for single-stream compression."
        )
      end

      def tool_error(format)
        Cvt::Errors.build(
          "backend_unavailable",
          "Neither #{format} nor 7-Zip is installed",
          hint: "#{Cvt::Bin.hint(format)} Alternatively install 7-Zip: #{Cvt::Bin.hint('7zip')}"
        )
      end
    end
  end
end
