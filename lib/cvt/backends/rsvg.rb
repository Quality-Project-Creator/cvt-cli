# frozen_string_literal: true

# Reference: librsvg (LGPL-2.1+) https://gitlab.gnome.org/GNOME/librsvg
require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"
require_relative "../adapters/image/options"

module Cvt
  # rsvg-convert adapter: SVG -> PNG/PDF. SVG is read-only in CVT 0.1.
  class RsvgBackend < Cvt::Backend
    id "rsvg"
    kind "cli"
    priority 15
    requirements ["rsvg-convert"]

    TARGETS = %w[png pdf].freeze

    def available?
      !binary.nil?
    rescue StandardError
      false
    end

    def version
      return @version if defined?(@version)

      path = binary
      @version = path && Cvt::Bin.version(path, ["--version"], /rsvg-convert version (\d+\.\d+\.\d+)/)
    end

    def available_for?(from, to, requirements = [])
      return false unless available?
      return false unless Array(requirements).all? { |name| requirement_satisfied?(name) }

      from.to_s == "svg" && TARGETS.include?(to.to_s)
    rescue StandardError
      false
    end

    def convert(input, output, options = {}, warnings = [])
      to = options["to"].to_s
      cli = binary or raise Cvt::Errors.build(
        "backend_unavailable", "rsvg-convert is not available",
        hint: Cvt::Bin.hint("librsvg")
      )

      Cvt::Adapters::Image::Options.quality(options, to: to, warnings: warnings)
      args = [cli, "--format", to == "pdf" ? "pdf" : "png"]
      width = Cvt::Adapters::Image::Options.dimension(options, "width")
      height = Cvt::Adapters::Image::Options.dimension(options, "height")
      if width || height
        args << "--keep-aspect-ratio"
        args += ["--width", width.to_s] if width
        args += ["--height", height.to_s] if height
      end
      args += ["--output", output, input]
      Cvt::Shell.run!(args, timeout: options["timeout"].to_i)
    rescue Cvt::Error => e
      raise e unless e.code == "conversion_failed"

      raise Cvt::Errors.build(
        e.code, "rsvg-convert could not render the SVG",
        hint: "Check that the SVG is valid; run with --debug for engine stderr.",
        details: e.details
      )
    rescue StandardError => e
      raise Cvt::Errors.build(
        "conversion_failed", "rsvg-convert could not render the SVG",
        hint: "Check that the SVG is valid; run with --debug for engine details.",
        details: { "stderr" => e.message }
      )
    end

    private

    def binary
      return @binary if defined?(@binary)

      @binary = Cvt::Bin.find("rsvg-convert", env_var: "CVT_BIN_RSVG_CONVERT")
    end

    def requirement_satisfied?(name)
      %w[rsvg-convert librsvg rsvg].include?(name.to_s) && available?
    end
  end
end
