# frozen_string_literal: true

# Reference: rubyzip (BSD-2-Clause) https://github.com/rubyzip/rubyzip
# Reference: RubyGems (Ruby License) https://github.com/rubygems/rubygems
# Reference: zlib (zlib license) https://zlib.net
# Reference: XZ Utils (0BSD) https://tukaani.org/xz
# Reference: bzip2 (bzip2 license) https://sourceware.org/bzip2
# Reference: 7-Zip (LGPL-2.1+) https://www.7-zip.org

require "fileutils"

require_relative "../backend"
require_relative "../errors"
require_relative "../adapters/archive/containers"
require_relative "../adapters/archive/streams"
require_relative "../adapters/archive/tools"

module Cvt
  module Backends
    # ZIP/TAR/TGZ member repacking plus single-stream gz/xz/bz2
    # recompression. Containers never extract to disk; entry streams are
    # repacked directly and unsafe entries abort before any output is kept.
    class NativeArchive < Cvt::Backend
      id "native_archive"
      kind "native+cli"
      priority 5
      requirements []

      FORMATS = Cvt::Adapters::Archive::CONTAINERS + Cvt::Adapters::Archive::STREAMS
      STREAM_TOOLS = { "xz" => "xz", "bz2" => "bzip2" }.freeze

      def available?
        true
      end

      def available_for?(from, to, requirements = [])
        from = from.to_s
        to = to.to_s
        return false if from == to
        return false unless FORMATS.include?(from) && FORMATS.include?(to)

        if Cvt::Adapters::Archive::CONTAINERS.include?(from) &&
           Cvt::Adapters::Archive::CONTAINERS.include?(to)
          true
        elsif Cvt::Adapters::Archive::STREAMS.include?(from) &&
              Cvt::Adapters::Archive::STREAMS.include?(to)
          implied = [from, to].filter_map { |format| STREAM_TOOLS[format] }.uniq
          Cvt::Adapters::Archive.requirements_available?(requirements) &&
            Cvt::Adapters::Archive.requirements_available?(implied)
        else
          false
        end
      end

      def version
        spec = Gem.loaded_specs["rubyzip"]
        spec ? "rubyzip #{spec.version}, zlib #{Zlib.zlib_version}" : "zlib #{Zlib.zlib_version}"
      end

      def convert(input, output, options = {}, warnings = [])
        from = options["from"].to_s
        to = options["to"].to_s

        if container_pair?(from, to)
          Cvt::Adapters::Archive.repack(input, output, from, to, options, warnings)
        elsif stream_pair?(from, to)
          Cvt::Adapters::Streams.recompress(input, output, from, to, options, warnings)
        else
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "native_archive cannot convert #{from} to #{to}",
            hint: "Use zip/tar/tgz for archives or gz/xz/bz2 for single streams."
          )
        end

        warnings
      rescue Cvt::Error
        FileUtils.rm_f(output)
        raise
      rescue StandardError => e
        FileUtils.rm_f(output)
        raise Cvt::Errors.build(
          "conversion_failed",
          "Archive conversion failed: #{e.message.to_s.lines.first.to_s.strip}",
          hint: "Check that the input archive is valid and uses supported entry types."
        )
      end

      private

      def container_pair?(from, to)
        Cvt::Adapters::Archive::CONTAINERS.include?(from) &&
          Cvt::Adapters::Archive::CONTAINERS.include?(to) && from != to
      end

      def stream_pair?(from, to)
        Cvt::Adapters::Archive::STREAMS.include?(from) &&
          Cvt::Adapters::Archive::STREAMS.include?(to) && from != to
      end
    end
  end
end
