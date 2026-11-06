# frozen_string_literal: true

# Reference: prawn (Ruby License) https://github.com/prawnpdf/prawn
require_relative "../../errors"
require_relative "../image/options"

module Cvt
  module Adapters
    module Pdf
      # Minimal PNG/JPEG header reader: Prawn needs the page orientation
      # before the image is placed, and the alpha strip needs the color type.
      module Dimensions
        PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

        module_function

        def read(path)
          data = File.binread(path)
          if data.start_with?(PNG_SIGNATURE)
            parse_png(data)
          elsif data.start_with?("\xFF\xD8".b)
            parse_jpeg(data)
          else
            raise Cvt::Errors.build(
              "conversion_failed", "Unsupported image for PDF embedding",
              hint: "Image to PDF supports PNG and JPEG inputs."
            )
          end
        end

        def parse_png(data)
          width = data.byteslice(16, 4).unpack1("N")
          height = data.byteslice(20, 4).unpack1("N")
          color_type = data.getbyte(25)
          alpha = color_type == 4 || color_type == 6 || png_has_transparency?(data)
          [width, height, alpha]
        end

        def png_has_transparency?(data)
          offset = 8
          while offset + 8 <= data.bytesize
            length = data.byteslice(offset, 4).unpack1("N")
            type = data.byteslice(offset + 4, 4)
            return true if type == "tRNS"
            return false if type == "IDAT" || type == "IEND"

            offset += 12 + length
          end
          false
        end

        def parse_jpeg(data)
          offset = 2
          while offset + 9 <= data.bytesize
            marker = data.getbyte(offset + 1)
            return nil if marker.nil? || data.getbyte(offset) != 0xFF

            offset += 2
            next if marker == 0xD8 || (0xD0..0xD7).cover?(marker)
            break if marker == 0xD9 || marker == 0xDA

            length = data.byteslice(offset, 2).unpack1("n")
            start_of_frame = (0xC0..0xCF).cover?(marker) && ![0xC4, 0xC8, 0xCC].include?(marker)
            if start_of_frame
              height = data.byteslice(offset + 3, 2).unpack1("n")
              width = data.byteslice(offset + 5, 2).unpack1("n")
              return [width, height, false]
            end
            offset += length
          end

          raise Cvt::Errors.build(
            "conversion_failed", "Could not read the JPEG dimensions",
            hint: "Check that the JPEG file is not truncated."
          )
        end
      end

      # Renders a single PNG/JPEG image onto one A4 page (auto orientation,
      # 18pt margins, aspect-preserving fit, alpha composited on white).
      class ImageDocument
        MARGIN = 18

        def initialize(input, warnings = [])
          @input = input
          @warnings = warnings
        end

        def render(output)
          require "prawn"

          width, height, alpha = Dimensions.read(@input)
          orientation = width > height ? :landscape : :portrait
          pdf = Prawn::Document.new(page_size: "A4", margin: MARGIN, page_layout: orientation)
          if alpha
            @warnings << Cvt::Adapters::Image::Options.warning(
              "alpha_flattened",
              "Transparency was flattened onto a white background."
            )
            pdf.fill_color("FFFFFF")
            pdf.fill_rectangle([0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height)
          end
          pdf.image(@input, position: :center, vposition: :center,
                            fit: [pdf.bounds.width, pdf.bounds.height])
          pdf.render_file(output)
        rescue Cvt::Error
          raise
        rescue LoadError => e
          raise Cvt::Errors.build(
            "backend_unavailable", "The prawn gem is required for image to PDF",
            hint: "Install the prawn gem: gem install prawn.",
            details: { "stderr" => e.message }
          )
        rescue StandardError => e
          raise Cvt::Errors.build(
            "conversion_failed", "Could not create a PDF from the image",
            hint: "Check that the image is a valid PNG or JPEG file.",
            details: { "stderr" => e.message }
          )
        end
      end
    end
  end
end
