# frozen_string_literal: true

# Reference: pandoc (GPL-2.0-or-later) https://github.com/jgm/pandoc
# Integrated as a subprocess engine only; no Pandoc source is copied here.

require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"

module Cvt
  module Backends
    # Document conversion through the Pandoc executable. Pandoc is never used
    # for PDF output; PDF paths belong to LibreOffice, Calibre, or the PDF
    # backend.
    class Pandoc < Cvt::Backend
      id "pandoc"
      kind "cli"
      priority 12
      requirements []

      FORMATS = %w[md html docx odt rst tex epub].freeze
      PANDOC_NAMES = {
        "md" => "markdown",
        "tex" => "latex"
      }.freeze

      def binary
        Cvt::Bin.find(["pandoc"], env_var: "CVT_BIN_PANDOC")
      end

      def available?
        !binary.nil?
      end

      def available_for?(from, to, requirements = [])
        return false unless available?
        return false unless requirements_available?(requirements)

        from = from.to_s
        to = to.to_s
        from != to && FORMATS.include?(from) && FORMATS.include?(to)
      end

      def version
        Cvt::Bin.version(binary, ["--version"], /pandoc\s+([0-9][0-9.]*)/)
      end

      def convert(input, output, options = {}, warnings = [])
        unless available?
          raise Cvt::Errors.build(
            "backend_unavailable",
            "Pandoc is not installed",
            hint: "#{Cvt::Bin.hint('pandoc')} Or set CVT_BIN_PANDOC."
          )
        end

        from = options["from"].to_s
        to = options["to"].to_s
        unless available_for?(from, to, [])
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "Pandoc cannot convert #{from} to #{to}",
            hint: "Use cvt --formats to see supported document conversions."
          )
        end

        argv = [
          binary, input,
          "--from", PANDOC_NAMES.fetch(from, from),
          "--to", PANDOC_NAMES.fetch(to, to),
          "-o", output
        ]
        Cvt::Shell.run!(argv, timeout: options.fetch("timeout", 300).to_i)

        unless File.file?(output)
          raise Cvt::Errors.build(
            "conversion_failed",
            "Pandoc did not produce an output file",
            hint: "Run with --debug to inspect the engine output."
          )
        end

        warnings
      end

      private

      def requirements_available?(requirements)
        Array(requirements).all? { |tool| Cvt::Bin.find([tool.to_s]) }
      end
    end
  end
end
