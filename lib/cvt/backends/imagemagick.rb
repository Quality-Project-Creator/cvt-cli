# frozen_string_literal: true

# Reference: ImageMagick (ImageMagick License) https://imagemagick.org/
# Reference: mini_magick (MIT) https://github.com/minimagick/minimagick
require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"
require_relative "../adapters/image/options"

module Cvt
  # ImageMagick adapter: BMP/PNM/TGA/ICO/GIF (including animated GIF), SVG
  # fallback, and the generic raster fallback for libvips. On Windows only
  # `magick` is used so `convert.exe` (the filesystem tool) is never executed.
  class ImageMagickBackend < Cvt::Backend
    id "imagemagick"
    kind "gem+cli"
    priority 20
    requirements ["imagemagick"]

    FROM_FORMATS = %w[png jpg webp gif bmp tiff ico avif heic pnm tga svg].freeze
    TO_FORMATS = (Cvt::Adapters::Image::Options::LOSSY_FORMATS +
                  %w[png gif bmp tiff ico pnm tga]).freeze
    FORMAT_TOKENS = {
      "png" => "PNG", "jpg" => "JPEG", "webp" => "WEBP", "gif" => "GIF",
      "bmp" => "BMP", "tiff" => "TIFF", "ico" => "ICON", "avif" => "AVIF",
      "heic" => "HEIC", "pnm" => "PNM", "tga" => "TGA"
    }.freeze

    def available?
      !binary.nil? && !mini_magick.nil?
    rescue StandardError
      false
    end

    def version
      return @version if defined?(@version)

      path = binary
      @version = path && Cvt::Bin.version(path, ["-version"], /ImageMagick (\d+\.\d+\.\d+(?:-\d+)?)/)
    end

    def available_for?(from, to, requirements = [])
      return false unless available?
      return false unless Array(requirements).all? { |name| requirement_satisfied?(name) }
      return false unless FROM_FORMATS.include?(from.to_s) && TO_FORMATS.include?(to.to_s)
      return false if from.to_s == "svg" && to.to_s != "png"

      writable_format?(to.to_s)
    rescue StandardError
      false
    end

    def convert(input, output, options = {}, warnings = [])
      from = options["from"].to_s
      to = options["to"].to_s
      cli = binary
      unless cli && mini_magick
        raise Cvt::Errors.build(
          "backend_unavailable", "ImageMagick is not available",
          hint: "#{Cvt::Bin.hint('imagemagick')} The mini_magick gem is also required."
        )
      end

      info = identify_info(input) if from == "gif" || to == "jpg"
      source = input
      if from == "gif" && !%w[gif tiff].include?(to)
        source = "#{input}[0]"
        if info[:frames].to_i > 1
          warnings << Cvt::Adapters::Image::Options.warning(
            "animation_lost",
            "Animation frames were lost; only the first frame was written."
          )
        end
      end

      tool = new_tool(cli)
      quality = Cvt::Adapters::Image::Options.quality(options, to: to, warnings: warnings)
      tool << source
      tool.auto_orient
      unless Cvt::Adapters::Image::Options.keep_metadata?(options)
        tool.strip
        warnings << Cvt::Adapters::Image::Options.warning(
          "metadata_stripped",
          "Metadata was stripped; pass --keep-metadata to keep it when possible."
        )
      end
      resize_arguments(tool, options, to)
      flatten_alpha(tool, info, to, warnings)
      tool.quality(quality.to_s) if Cvt::Adapters::Image::Options::LOSSY_FORMATS.include?(to)
      tool << output

      Cvt::Shell.run!(tool.command, timeout: timeout(options))
    rescue Cvt::Error => e
      raise e unless e.code == "conversion_failed"

      raise Cvt::Errors.build(
        e.code, "ImageMagick could not convert #{from} to #{to}",
        hint: "Check that the input image is valid; run with --debug for engine stderr.",
        details: e.details
      )
    rescue StandardError => e
      raise Cvt::Errors.build(
        "conversion_failed", "ImageMagick could not convert #{from} to #{to}",
        hint: "Check that the input image is valid; run with --debug for engine details.",
        details: { "stderr" => e.message }
      )
    end

    private

    def binary
      return @binary if defined?(@binary)

      @binary = Cvt::Bin.imagemagick
    end

    def mini_magick
      return @mini_magick if defined?(@mini_magick)

      @mini_magick = begin
        require "mini_magick"
        true
      rescue LoadError, StandardError
        nil
      end
    end

    def requirement_satisfied?(name)
      %w[imagemagick magick convert].include?(name.to_s) && available?
    end

    # MiniMagick builds the argv array; the executable is pinned to the binary
    # found by Cvt::Bin so CVT_BIN_MAGICK always wins.
    def new_tool(cli)
      tool = MiniMagick::Tool.new(cli)
      tool.define_singleton_method(:executable) { [cli] }
      tool
    end

    def timeout(options)
      options["timeout"].to_i
    end

    def resize_arguments(tool, options, to)
      if to == "ico"
        width, height = Cvt::Adapters::Image::Options.ico_box(options)
        tool.resize("#{width}x#{height}")
        return
      end

      width = Cvt::Adapters::Image::Options.dimension(options, "width")
      height = Cvt::Adapters::Image::Options.dimension(options, "height")
      return if width.nil? && height.nil?

      tool.resize("#{width || ''}x#{height || ''}")
    end

    def flatten_alpha(tool, info, to, warnings)
      return unless to == "jpg"

      tool.merge!(["-background", "white", "-alpha", "remove", "-alpha", "off"])
      return unless info[:alpha]

      warnings << Cvt::Adapters::Image::Options.warning(
        "alpha_flattened",
        "Transparency was flattened onto a white background."
      )
    end

    # Frame count and alpha channel, read with the same configured binary
    # family. Missing identify support degrades to empty info.
    def identify_info(input)
      command = identify_command
      return {} unless command

      result = Cvt::Shell.run(command + ["-format", "%w\t%h\t%n\t%A\n", input], timeout: 10)
      return {} unless result.success?

      parts = result.stdout.lines.first.to_s.chomp.split("\t")
      return {} if parts.size < 4

      { width: parts[0].to_i, height: parts[1].to_i, frames: parts[2].to_i, alpha: parts[3] == "True" }
    rescue StandardError
      {}
    end

    def identify_command
      return [binary, "identify"] if File.basename(binary.to_s).downcase.match?(/\A(magick|magick\.exe)\z/)

      path = Cvt::Bin.find("identify") || sibling_executable("identify")
      path ? [path] : nil
    end

    def sibling_executable(name)
      directory = File.dirname(binary.to_s)
      candidate = File.join(directory, Gem.win_platform? ? "#{name}.exe" : name)
      File.file?(candidate) && File.executable?(candidate) ? candidate : nil
    rescue StandardError
      nil
    end

    # ImageMagick reports delegate support in `-list format`; AVIF/HEIC are
    # often read-only, so the route must not claim they can be written.
    def writable_format?(to)
      token = FORMAT_TOKENS[to]
      return false unless token

      table = format_table
      flags = table && table[/^\s*#{token}\*?(?:\s+[A-Za-z0-9]+)?\s+([-+rw]{3})/i, 1]
      !!(flags && flags.start_with?("rw"))
    end

    def format_table
      return @format_table if defined?(@format_table)

      result = Cvt::Shell.run([binary, "-list", "format"], timeout: 20)
      @format_table = result.success? ? result.stdout : nil
    end
  end
end
