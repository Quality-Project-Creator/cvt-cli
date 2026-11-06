# frozen_string_literal: true

# Reference: libvips (LGPL-2.1) https://www.libvips.org/
# Reference: ruby-vips (MIT) https://github.com/libvips/ruby-vips
require "tmpdir"

require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"
require_relative "../adapters/image/options"

module Cvt
  # libvips adapter: preferred raster image engine (PNG/JPEG/WebP/TIFF/AVIF/
  # HEIC) and the last-resort PDF rasterizer (first page only).
  class VipsBackend < Cvt::Backend
    id "vips"
    kind "gem"
    priority 10
    requirements ["libvips"]

    LOAD_OPERATIONS = {
      "png" => "pngload",
      "jpg" => "jpegload",
      "webp" => "webpload",
      "tiff" => "tiffload",
      "avif" => "heifload",
      "heic" => "heifload",
      "pdf" => "pdfload"
    }.freeze
    SAVE_OPERATIONS = {
      "png" => "pngsave",
      "jpg" => "jpegsave",
      "webp" => "webpsave",
      "tiff" => "tiffsave",
      "avif" => "heifsave",
      "heic" => "heifsave"
    }.freeze

    def available?
      !lib_vips.nil?
    rescue StandardError
      false
    end

    def version
      lib_vips ? Vips.version_string : nil
    rescue StandardError
      nil
    end

    def available_for?(from, to, requirements = [])
      return false unless available?
      return false unless Array(requirements).all? { |name| requirement_satisfied?(name) }

      load_supported?(from.to_s) && save_supported?(to.to_s)
    rescue StandardError
      false
    end

    def convert(input, output, options = {}, warnings = [])
      from = options["from"].to_s
      to = options["to"].to_s
      lib_vips or raise Cvt::Errors.build(
        "backend_unavailable", "libvips is not available",
        hint: "#{Cvt::Bin.hint('libvips')} Then install the ruby-vips gem."
      )

      image = load_image(input, from, options)
      image = image.autorot
      image = resize(image, options)
      image = flatten(image, from, to, warnings)
      strip = !Cvt::Adapters::Image::Options.keep_metadata?(options)
      if strip && from != "pdf"
        warnings << Cvt::Adapters::Image::Options.warning(
          "metadata_stripped",
          "Metadata was stripped; pass --keep-metadata to keep it when possible."
        )
      end
      quality = Cvt::Adapters::Image::Options.quality(options, to: to, warnings: warnings)
      save(image, output, to, quality, strip)
    rescue Cvt::Error
      raise
    rescue StandardError => e
      raise Cvt::Errors.build(
        "conversion_failed", "libvips could not convert #{from} to #{to}",
        hint: "Check that the input image is valid; run with --debug for engine details.",
        details: { "stderr" => e.message }
      )
    end

    private

    def lib_vips
      return @lib_vips if defined?(@lib_vips)

      @lib_vips = begin
        require "vips"
        Vips
      rescue LoadError, StandardError
        nil
      end
    end

    def requirement_satisfied?(name)
      %w[libvips vips].include?(name.to_s) && available?
    end

    def load_supported?(from)
      operation_supported?(LOAD_OPERATIONS[from])
    end

    def save_supported?(to)
      operation = SAVE_OPERATIONS[to]
      return false unless operation_supported?(operation)

      %w[avif heic].include?(to) ? encoder_available?(to) : true
    end

    def operation_supported?(name)
      return false if name.nil?

      @operations ||= {}
      @operations[name] = !!Vips.type_find("VipsOperation", name) unless @operations.key?(name)
      @operations[name]
    end

    # libheif may be built with decoders only; report AVIF/HEIC writing only
    # when a real encode succeeds, never based on the operation's existence.
    def encoder_available?(format)
      @encoders ||= {}
      return @encoders[format] if @encoders.key?(format)

      @encoders[format] = probe_encoder(format)
    end

    def probe_encoder(format)
      compression = format == "avif" ? "av1" : "hevc"
      Dir.mktmpdir("cvt-vips-probe-") do |dir|
        path = File.join(dir, "probe.#{format}")
        Vips::Image.black(8, 8, bands: 3).heifsave(path, compression: compression, Q: 40)
        File.file?(path) && File.size(path).positive?
      end
    rescue StandardError
      false
    end

    def load_image(input, from, options)
      if from == "pdf"
        page = Cvt::Adapters::Image::Options.page(options)
        if page > 1
          raise Cvt::Errors.build(
            "conversion_failed",
            "The libvips PDF fallback can only rasterize page 1",
            hint: "Install Poppler (pdftoppm) to select other pages, or convert page 1."
          )
        end
        return Vips::Image.new_from_file(input, page: 0, n: 1,
                                                dpi: Cvt::Adapters::Image::Options.dpi(options),
                                                access: :sequential)
      end

      Vips::Image.new_from_file(input, access: :sequential)
    end

    def resize(image, options)
      scale = Cvt::Adapters::Image::Options.fit_scale(
        image.width, image.height,
        Cvt::Adapters::Image::Options.dimension(options, "width"),
        Cvt::Adapters::Image::Options.dimension(options, "height")
      )
      return image if scale.nil? || (scale - 1.0).abs < 1e-9

      image.resize(scale, kernel: :lanczos3)
    end

    def flatten(image, from, to, warnings)
      return image unless to == "jpg" && from != "pdf" && image.respond_to?(:has_alpha?) && image.has_alpha?

      warnings << Cvt::Adapters::Image::Options.warning(
        "alpha_flattened",
        "Transparency was flattened onto a white background."
      )
      image.flatten(background: [255, 255, 255])
    end

    def save(image, output, to, quality, strip)
      case to
      when "jpg"
        image.jpegsave(output, Q: quality, strip: strip)
      when "webp"
        image.webpsave(output, Q: quality, strip: strip)
      when "png"
        image.pngsave(output, strip: strip)
      when "tiff"
        image.tiffsave(output, strip: strip)
      when "avif"
        image.heifsave(output, compression: "av1", Q: quality, strip: strip)
      when "heic"
        image.heifsave(output, compression: "hevc", Q: quality, strip: strip)
      else
        raise Cvt::Errors.build(
          "unsupported_conversion", "libvips cannot write #{to} output",
          hint: "Run cvt --formats to see supported image formats."
        )
      end
    end
  end
end
