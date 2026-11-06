# frozen_string_literal: true

# Reference: mini_magick (MIT) https://github.com/minimagick/minimagick
# Reference: libvips (LGPL-2.1) https://www.libvips.org/
require_relative "../../errors"

module Cvt
  module Adapters
    module Image
      # Shared normalization for the image-related CLI options. Backends call
      # these helpers so range checks, defaults, and warning codes stay
      # consistent across libvips, ImageMagick, rsvg, and the PDF writers.
      module Options
        LOSSY_FORMATS = %w[jpg webp avif heic].freeze
        DEFAULT_QUALITY = 85
        DEFAULT_DPI = 150
        DEFAULT_PAGE = 1
        ICO_MIN = 16
        ICO_MAX = 256
        ICO_DEFAULT = 256

        module_function

        def warning(code, message)
          { "code" => code.to_s, "message" => message.to_s }
        end

        # Returns the 1-100 lossy quality. A non-default quality on a lossless
        # target is reported as option_ignored (the CLI always sends the
        # default, so only an explicit user value is a real request).
        def quality(options, to:, warnings: [])
          value = options["quality"]
          value = DEFAULT_QUALITY if value.nil?
          unless value.is_a?(Integer) && value.between?(1, 100)
            raise Cvt::Errors.build(
              "usage_error", "Image quality must be an integer between 1 and 100",
              hint: "Pass --quality with a value from 1 to 100."
            )
          end
          if !LOSSY_FORMATS.include?(to.to_s) && value != DEFAULT_QUALITY
            warnings << warning("option_ignored",
                                "Option --quality does not apply to #{to} output and was ignored.")
          end
          value
        end

        def dpi(options)
          value = options["dpi"]
          return DEFAULT_DPI if value.nil?
          return value if value.is_a?(Integer) && value.between?(1, 600)

          raise Cvt::Errors.build(
            "usage_error", "PDF rasterization DPI must be an integer between 1 and 600",
            hint: "Pass --dpi with a value from 1 to 600."
          )
        end

        def page(options)
          value = options["page"]
          return DEFAULT_PAGE if value.nil?
          return value if value.is_a?(Integer) && value >= 1

          raise Cvt::Errors.build(
            "usage_error", "PDF page must be a positive integer",
            hint: "Pass --page with a page number starting at 1."
          )
        end

        def keep_metadata?(options)
          !!options["keep_metadata"]
        end

        def dimension(options, key)
          value = options[key]
          return nil if value.nil?

          value = Integer(value)
          return value if value >= 1

          raise ArgumentError, "#{key} must be positive"
        rescue ArgumentError, TypeError
          raise Cvt::Errors.build(
            "usage_error", "Image #{key} must be a positive integer",
            hint: "Pass --#{key} with a positive pixel value."
          )
        end

        # Scale factor that fits within the optional bounds while preserving
        # the aspect ratio. Upscaling is allowed; no cropping is performed.
        def fit_scale(pixel_width, pixel_height, max_width, max_height)
          return nil if max_width.nil? && max_height.nil?
          return nil unless pixel_width.to_i.positive? && pixel_height.to_i.positive?

          width_ratio = max_width ? max_width.to_f / pixel_width : Float::INFINITY
          height_ratio = max_height ? max_height.to_f / pixel_height : Float::INFINITY
          [width_ratio, height_ratio].min
        end

        # Single-size ICO bounds (16-256 px per axis, default 256).
        def ico_box(options)
          width = dimension(options, "width")
          height = dimension(options, "height")
          width ||= ICO_DEFAULT
          height ||= ICO_DEFAULT
          [width, height].each do |value|
            next if value.between?(ICO_MIN, ICO_MAX)

            raise Cvt::Errors.build(
              "usage_error", "ICO size must be between #{ICO_MIN} and #{ICO_MAX} pixels",
              hint: "Pass --width/--height values from #{ICO_MIN} to #{ICO_MAX} for ICO output."
            )
          end
          [width, height]
        end
      end
    end
  end
end
