# frozen_string_literal: true

# Reference: LibreOffice (MPL-2.0 with LGPL/GPL components)
# https://github.com/LibreOffice/core
# Integrated as a subprocess engine only; no LibreOffice source is copied here.

require "fileutils"
require "tmpdir"

require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"

module Cvt
  module Backends
    # Office and spreadsheet conversion through a headless LibreOffice
    # instance. Every call gets a private UserInstallation profile so it never
    # collides with a running desktop instance. The engine writes into a
    # temporary directory and the produced file is moved to the exact output
    # path afterwards.
    class LibreOffice < Cvt::Backend
      id "libreoffice"
      kind "cli"
      priority 15
      requirements []

      WRITER_INPUTS = %w[docx odt rtf html txt].freeze
      CALC_INPUTS = %w[xlsx ods csv].freeze

      WRITER_FILTERS = {
        "docx" => "MS Word 2007 XML",
        "odt" => "writer8",
        "rtf" => "Rich Text Format",
        "html" => "HTML (StarWriter)",
        "txt" => "Text (encoded):UTF8",
        "pdf" => "writer_pdf_Export"
      }.freeze

      CALC_FILTERS = {
        "xlsx" => "Calc MS Excel 2007 XML",
        "ods" => "calc8",
        "pdf" => "calc_pdf_Export",
        "html" => "HTML (StarCalc)",
        "txt" => "Text - txt - csv (StarCalc)"
      }.freeze

      PROTECTED_PATTERN = /password|encrypted|protected/i

      def binary
        found = Cvt::Bin.find(%w[soffice libreoffice], env_var: "CVT_BIN_SOFFICE")
        return found if found

        fallback_paths.find { |path| File.file?(path) && File.executable?(path) }
      end

      def available?
        !binary.nil?
      end

      def available_for?(from, to, requirements = [])
        return false unless available?
        return false unless requirements_available?(requirements)
        return false if from.to_s == to.to_s

        !filter_spec(from.to_s, to.to_s).nil?
      end

      def version
        Cvt::Bin.version(binary, ["--version"], /LibreOffice\s+([0-9][0-9.]*)/)
      end

      def convert(input, output, options = {}, warnings = [])
        unless available?
          raise Cvt::Errors.build(
            "backend_unavailable",
            "LibreOffice is not installed",
            hint: "#{Cvt::Bin.hint('libreoffice')} Or set CVT_BIN_SOFFICE."
          )
        end

        from = options["from"].to_s
        to = options["to"].to_s
        spec = filter_spec(from, to)
        unless spec
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "LibreOffice cannot convert #{from} to #{to}",
            hint: "Choose a supported office target or convert through PDF."
          )
        end

        add_warnings(warnings, to)
        timeout = options.fetch("timeout", 300).to_i

        Dir.mktmpdir("cvt-libreoffice-") do |tmpdir|
          outdir = File.join(tmpdir, "out")
          FileUtils.mkdir_p(outdir)
          profile = File.join(tmpdir, "profile")

          argv = [
            binary,
            "--headless",
            "--norestore",
            "--nofirststartwizard",
            "-env:UserInstallation=#{user_installation_url(profile)}",
            "--convert-to", spec,
            "--outdir", outdir,
            input
          ]
          result = Cvt::Shell.run(argv, timeout: timeout)
          raise timeout_error(timeout, result) if result.timed_out?

          produced = produced_path(outdir, input, to)
          if produced.nil? || !result.success?
            raise conversion_error(from, to, result)
          end

          FileUtils.mv(produced, output, force: true)
        end

        unless File.file?(output)
          raise Cvt::Errors.build(
            "conversion_failed",
            "LibreOffice did not produce an output file",
            hint: "Run with --debug to inspect the engine output."
          )
        end

        warnings
      end

      private

      # LibreOffice expects a file: URL. Windows drive paths (C:/...) need the
      # third slash that POSIX paths already provide.
      def user_installation_url(path)
        normalized = path.tr("\\", "/")
        normalized.start_with?("/") ? "file://#{normalized}" : "file:///#{normalized}"
      end

      def filter_spec(from, to)
        filters = if WRITER_INPUTS.include?(from)
                    WRITER_FILTERS
                  elsif CALC_INPUTS.include?(from)
                    CALC_FILTERS
                  end
        filter = filters && filters[to]
        filter && "#{to}:#{filter}"
      end

      def requirements_available?(requirements)
        Array(requirements).all? { |tool| Cvt::Bin.find([tool.to_s]) }
      end

      def produced_path(outdir, input, to)
        base = File.basename(input, File.extname(input))
        expected = File.join(outdir, "#{base}.#{to}")
        return expected if File.file?(expected)

        Dir.glob(File.join(outdir, "*.#{to}")).find { |path| File.file?(path) }
      end

      def add_warnings(warnings, to)
        return unless %w[txt html].include?(to)
        return if warnings.any? { |warning| warning["code"] == "style_loss" }

        warnings << {
          "code" => "style_loss",
          "message" => "Formatting, layout, and styles are not fully preserved in #{to} output."
        }
      end

      def timeout_error(timeout, result)
        Cvt::Errors.build(
          "timeout",
          "LibreOffice timed out after #{timeout} seconds",
          hint: "Increase --timeout or use a smaller document.",
          details: stderr_details(result)
        )
      end

      def conversion_error(from, to, result)
        combined = "#{result.stdout}\n#{result.stderr}"
        if PROTECTED_PATTERN.match?(combined)
          Cvt::Errors.build(
            "input_protected",
            "Input document is password-protected",
            hint: "Remove the password protection from the document and try again.",
            details: stderr_details(result)
          )
        else
          Cvt::Errors.build(
            "conversion_failed",
            "LibreOffice failed to convert #{from} to #{to}",
            hint: "Check that the input is a valid #{from} document, or run with --debug for engine stderr.",
            details: stderr_details(result)
          )
        end
      end

      def stderr_details(result)
        return nil if result.stderr.to_s.empty?

        { "stderr" => Cvt::Shell.truncate(result.stderr) }
      end

      def fallback_paths
        case Cvt::Bin.platform
        when "macos"
          [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            File.expand_path("~/Applications/LibreOffice.app/Contents/MacOS/soffice")
          ]
        when "windows"
          [
            'C:\Program Files\LibreOffice\program\soffice.exe',
            'C:\Program Files (x86)\LibreOffice\program\soffice.exe'
          ]
        else
          []
        end
      end
    end
  end
end
