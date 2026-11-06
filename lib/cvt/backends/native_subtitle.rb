# frozen_string_literal: true

# Reference: srt (MIT) https://github.com/cpetersen/srt

require "srt"

require_relative "../backend"
require_relative "../errors"
require_relative "../adapters/subtitle/subtitles"

module Cvt
  module Backends
    # SRT/VTT/ASS conversion through the shared cue model. All six pairs are
    # native; no external engine is required.
    class NativeSubtitle < Cvt::Backend
      id "native_subtitle"
      kind "native"
      priority 5
      requirements []

      FORMATS = Cvt::Adapters::Subtitle::FORMATS

      def available?
        true
      end

      def available_for?(from, to, _requirements = [])
        from = from.to_s
        to = to.to_s
        FORMATS.include?(from) && FORMATS.include?(to) && from != to
      end

      def version
        spec = Gem.loaded_specs["srt"]
        spec ? "srt #{spec.version}" : nil
      end

      def convert(input, output, options = {}, warnings = [])
        Cvt::Adapters::Subtitle.convert(input, output, options["from"], options["to"], warnings)
      rescue Cvt::Error
        raise
      rescue StandardError => e
        raise Cvt::Errors.build(
          "conversion_failed",
          "Subtitle conversion failed: #{e.message.to_s.lines.first.to_s.strip}",
          hint: "Check that the input uses valid SRT, VTT, or ASS cue syntax."
        )
      end
    end
  end
end
