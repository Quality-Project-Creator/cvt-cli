# frozen_string_literal: true

# Reference: Poppler (GPL-2.0+) https://poppler.freedesktop.org/
require "fileutils"
require "tmpdir"

require_relative "../../bin"
require_relative "../../errors"
require_relative "../../shell"

module Cvt
  module Adapters
    module Pdf
      # Poppler CLI helpers: pdftoppm rasterizes one page per call, pdftotext
      # extracts text. Both write through temporary files/directories so a
      # failure never leaves a partial output behind.
      module Poppler
        ENCRYPTED_PATTERN = /encrypt|password/i

        module_function

        def pdftoppm
          Cvt::Bin.find("pdftoppm", env_var: "CVT_BIN_PDFTOPPM")
        end

        def pdftotext
          Cvt::Bin.find("pdftotext", env_var: "CVT_BIN_PDFTOTEXT")
        end

        def version
          path = pdftoppm || pdftotext
          return nil unless path

          Cvt::Bin.version(path, ["-v"], /version (\d+\.\d+\.\d+)/)
        end

        # Rasterizes exactly one page into `output` (PNG or JPG).
        def rasterize(input, output, page:, dpi:, format:, quality:, timeout:)
          cli = pdftoppm
          unless cli
            raise Cvt::Errors.build(
              "backend_unavailable", "Poppler pdftoppm is not available",
              hint: Cvt::Bin.hint("poppler")
            )
          end

          Dir.mktmpdir("cvt-poppler-") do |dir|
            prefix = File.join(dir, "page")
            args = [cli, "-r", dpi.to_s, "-f", page.to_s, "-l", page.to_s]
            args += format == "jpg" ? ["-jpeg", "-jpegopt", "quality=#{quality}"] : ["-png"]
            args += [input, prefix]

            begin
              Cvt::Shell.run!(args, timeout: timeout.to_i)
            rescue Cvt::Error => e
              raise protected_error if e.code == "conversion_failed" && encrypted?(e)
              raise e unless e.code == "conversion_failed"

              raise Cvt::Errors.build(
                e.code, "Poppler could not rasterize page #{page} of the PDF",
                hint: "Check that the PDF is valid and that page #{page} exists.",
                details: e.details
              )
            end

            produced = Dir["#{prefix}-*"].sort.first
            unless produced
              raise Cvt::Errors.build(
                "conversion_failed", "Poppler produced no image for page #{page}",
                hint: "Check that page #{page} exists in the PDF."
              )
            end

            FileUtils.mv(produced, output)
          end
        end

        def extract_text(input, page: nil, timeout: 0)
          cli = pdftotext
          unless cli
            raise Cvt::Errors.build(
              "backend_unavailable", "Poppler pdftotext is not available",
              hint: Cvt::Bin.hint("poppler")
            )
          end

          args = [cli, "-enc", "UTF-8"]
          args += ["-f", page.to_s, "-l", page.to_s] if page
          args += [input, "-"]

          begin
            Cvt::Shell.run!(args, timeout: timeout.to_i).stdout
          rescue Cvt::Error => e
            raise protected_error if e.code == "conversion_failed" && encrypted?(e)
            raise e unless e.code == "conversion_failed"

            raise Cvt::Errors.build(
              e.code, "Poppler could not extract text from the PDF",
              hint: "Check that the PDF is valid and that the selected page exists.",
              details: e.details
            )
          end
        end

        def encrypted?(error)
          details = error.respond_to?(:details) ? error.details : nil
          stderr = details.is_a?(Hash) ? details["stderr"].to_s : ""
          ENCRYPTED_PATTERN.match?(stderr)
        end

        def protected_error
          Cvt::Errors.build(
            "input_protected", "PDF is encrypted or password-protected",
            hint: "Remove the PDF password or decryption restrictions, then retry."
          )
        end
      end
    end
  end
end
