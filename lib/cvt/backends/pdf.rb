# frozen_string_literal: true

# Reference: pdf-reader (MIT) https://github.com/yob/pdf-reader
# Reference: prawn (Ruby License) https://github.com/prawnpdf/prawn
# Reference: Poppler (GPL-2.0+) https://poppler.freedesktop.org/
require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../adapters/image/options"
require_relative "../adapters/pdf/image_document"
require_relative "../adapters/pdf/poppler"
require_relative "../adapters/pdf/text_extractor"

module Cvt
  # PDF adapter: image -> PDF via Prawn, PDF -> PNG/JPG via Poppler
  # pdftoppm, PDF -> TXT via pdf-reader with a pdftotext fallback.
  class PdfBackend < Cvt::Backend
    id "pdf"
    kind "native+cli"
    priority 10
    requirements %w[pdf-reader prawn]

    def available?
      prawn_available? || reader_available? || !Cvt::Adapters::Pdf::Poppler.pdftoppm.nil?
    rescue StandardError
      false
    end

    def version
      @version ||= Cvt::Adapters::Pdf::Poppler.version || reader_version
    end

    def available_for?(from, to, requirements = [])
      return false unless available?
      return false unless Array(requirements).all? { |name| requirement_satisfied?(name) }

      case [from.to_s, to.to_s]
      when ["png", "pdf"], ["jpg", "pdf"]
        prawn_available?
      when ["pdf", "png"], ["pdf", "jpg"]
        !Cvt::Adapters::Pdf::Poppler.pdftoppm.nil?
      when ["pdf", "txt"]
        reader_available? || !Cvt::Adapters::Pdf::Poppler.pdftotext.nil?
      else
        false
      end
    rescue StandardError
      false
    end

    def convert(input, output, options = {}, warnings = [])
      from = options["from"].to_s
      to = options["to"].to_s

      case [from, to]
      when ["png", "pdf"], ["jpg", "pdf"]
        image_to_pdf(input, output, options, warnings)
      when ["pdf", "png"], ["pdf", "jpg"]
        pdf_to_image(input, output, options, warnings)
      when ["pdf", "txt"]
        pdf_to_text(input, output, options)
      else
        raise Cvt::Errors.build(
          "unsupported_conversion", "The PDF backend cannot convert #{from} to #{to}",
          hint: "Run cvt --formats to see supported PDF conversions."
        )
      end
    end

    private

    def image_to_pdf(input, output, options, warnings)
      Cvt::Adapters::Image::Options.quality(options, to: "pdf", warnings: warnings)
      Cvt::Adapters::Pdf::ImageDocument.new(input, warnings).render(output)
    end

    def pdf_to_image(input, output, options, warnings)
      to = options["to"].to_s
      quality = Cvt::Adapters::Image::Options.quality(options, to: to, warnings: warnings)
      Cvt::Adapters::Pdf::Poppler.rasterize(
        input, output,
        page: Cvt::Adapters::Image::Options.page(options),
        dpi: Cvt::Adapters::Image::Options.dpi(options),
        format: to,
        quality: quality,
        timeout: options["timeout"].to_i
      )
      warnings
    end

    def pdf_to_text(input, output, options)
      page = options["page"]
      page = Cvt::Adapters::Image::Options.page(options) unless page.nil?
      text = Cvt::Adapters::Pdf::TextExtractor.new(
        input,
        page: page,
        timeout: options["timeout"].to_i,
        pdftotext: Cvt::Adapters::Pdf::Poppler.pdftotext
      ).extract
      File.write(output, text)
    end

    def requirement_satisfied?(name)
      case name.to_s
      when "pdf-reader" then reader_available?
      when "prawn" then prawn_available?
      when "poppler", "pdftoppm" then !Cvt::Adapters::Pdf::Poppler.pdftoppm.nil?
      when "pdftotext" then !Cvt::Adapters::Pdf::Poppler.pdftotext.nil?
      else false
      end
    end

    def prawn_available?
      return @prawn_available unless @prawn_available.nil?

      @prawn_available = begin
        require "prawn"
        true
      rescue LoadError, StandardError
        false
      end
    end

    def reader_available?
      return @reader_available unless @reader_available.nil?

      @reader_available = begin
        require "pdf-reader"
        true
      rescue LoadError, StandardError
        false
      end
    end

    def reader_version
      return nil unless reader_available?

      spec = Gem.loaded_specs["pdf-reader"]
      spec ? spec.version.to_s : nil
    end
  end
end
