# frozen_string_literal: true

# Reference: Calibre (GPL-3.0) https://github.com/kovidgoyal/calibre
# Integrated as a subprocess engine only; no Calibre source is copied here.

require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"

module Cvt
  module Backends
    # Ebook conversion through `ebook-convert`. EPUB/MOBI/AZW3 can be
    # converted between each other or to PDF. The engine is optional; when it
    # is missing the backend reports itself unavailable instead of faking a
    # conversion.
    class Calibre < Cvt::Backend
      id "calibre"
      kind "cli"
      priority 12
      requirements []

      EBOOKS = %w[epub mobi azw3].freeze
      TARGETS = (EBOOKS + ["pdf"]).freeze
      PROTECTED_PATTERN = /drm|password|encrypted|protected/i

      def binary
        Cvt::Bin.find(["ebook-convert", "calibre"], env_var: "CVT_BIN_EBOOK_CONVERT")
      end

      def available?
        !binary.nil?
      end

      def available_for?(from, to, requirements = [])
        return false unless available?
        return false unless requirements_available?(requirements)

        from = from.to_s
        to = to.to_s
        from != to && EBOOKS.include?(from) && TARGETS.include?(to)
      end

      def version
        Cvt::Bin.version(binary, ["--version"], /([0-9]+\.[0-9]+\.[0-9]+)/)
      end

      def convert(input, output, options = {}, warnings = [])
        unless available?
          raise Cvt::Errors.build(
            "backend_unavailable",
            "Calibre is not installed",
            hint: "#{Cvt::Bin.hint('calibre')} Or set CVT_BIN_EBOOK_CONVERT."
          )
        end

        from = options["from"].to_s
        to = options["to"].to_s
        unless available_for?(from, to, [])
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "Calibre cannot convert #{from} to #{to}",
            hint: "Use cvt --formats to see supported ebook conversions."
          )
        end

        timeout = options.fetch("timeout", 300).to_i
        result = Cvt::Shell.run(
          [binary, input, output],
          timeout: timeout,
          env: {
            "QTWEBENGINE_DISABLE_SANDBOX" => "1",
            "QT_QPA_PLATFORM" => "offscreen"
          }
        )
        raise timeout_error(timeout, result) if result.timed_out?

        if !File.file?(output) || !result.success?
          raise conversion_error(from, to, result)
        end

        warnings
      end

      private

      def requirements_available?(requirements)
        Array(requirements).all? { |tool| Cvt::Bin.find([tool.to_s]) }
      end

      def timeout_error(timeout, result)
        Cvt::Errors.build(
          "timeout",
          "Calibre timed out after #{timeout} seconds",
          hint: "Increase --timeout or use a smaller ebook.",
          details: stderr_details(result)
        )
      end

      def conversion_error(from, to, result)
        if PROTECTED_PATTERN.match?("#{result.stdout}\n#{result.stderr}")
          Cvt::Errors.build(
            "input_protected",
            "Input ebook is protected by DRM or a password",
            hint: "Remove the protection from the ebook and try again.",
            details: stderr_details(result)
          )
        else
          Cvt::Errors.build(
            "conversion_failed",
            "Calibre failed to convert #{from} to #{to}",
            hint: "Check that the input is a valid #{from} ebook, or run with --debug for engine stderr.",
            details: stderr_details(result)
          )
        end
      end

      def stderr_details(result)
        return nil if result.stderr.to_s.empty?

        { "stderr" => Cvt::Shell.truncate(result.stderr) }
      end
    end
  end
end
