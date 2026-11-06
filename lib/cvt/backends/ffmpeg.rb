# frozen_string_literal: true

# Reference: FFmpeg (LGPL-2.1+; GPL-2.0+ when built with GPL components) https://ffmpeg.org

require_relative "../backend"
require_relative "../bin"
require_relative "../errors"
require_relative "../shell"

module Cvt
  # FFmpeg adapter for audio, video, video -> audio, and video -> GIF.
  # Output codecs are pinned to the table in spec R7; a missing encoder makes
  # the backend unavailable for that route instead of silently substituting.
  class FFmpegBackend < Cvt::Backend
    id "ffmpeg"
    kind "cli"
    requirements %w[ffmpeg ffprobe]

    AUDIO_FORMATS = %w[mp3 wav flac ogg opus aac m4a aiff].freeze
    VIDEO_FORMATS = %w[mp4 mkv webm mov avi m4v].freeze
    GIF_MAX_WIDTH = 480
    GIF_FPS = 12
    DEFAULT_AUDIO_BITRATE = "192k"

    OUTPUT_CODECS = {
      "mp3" => { audio: "libmp3lame", lossy_audio: true },
      "wav" => { audio: "pcm_s16le" },
      "flac" => { audio: "flac" },
      "ogg" => { audio: "libvorbis", lossy_audio: true },
      "opus" => { audio: "libopus", lossy_audio: true },
      "aac" => { audio: "aac", lossy_audio: true },
      "m4a" => { audio: "aac", lossy_audio: true },
      "aiff" => { audio: "pcm_s16be" },
      "mp4" => { video: "libx264", audio: "aac", crf: 23 },
      "m4v" => { video: "libx264", audio: "aac", crf: 23 },
      "webm" => { video: "libvpx-vp9", audio: "libopus", crf: 32 },
      "mkv" => { video: "libx264", audio: "aac", crf: 23 },
      "mov" => { video: "libx264", audio: "aac", crf: 23 },
      "avi" => { video: "mpeg4", audio: "libmp3lame" },
      "gif" => {}
    }.freeze

    def available?
      return @available unless @available.nil?

      @available = !ffmpeg_path.nil? && !ffprobe_path.nil? && !version.nil?
    end

    def available_for?(from, to, _requirements = [])
      from = from.to_s
      to = to.to_s
      return false unless available?
      return false unless supported_pair?(from, to)

      required_encoders(to).all? { |encoder| encoder_available?(encoder) }
    end

    def ffmpeg_path
      return @ffmpeg_path if defined?(@ffmpeg_path)

      @ffmpeg_path = Cvt::Bin.find(["ffmpeg"], env_var: "CVT_BIN_FFMPEG")
    end

    def ffprobe_path
      return @ffprobe_path if defined?(@ffprobe_path)

      @ffprobe_path = Cvt::Bin.find(["ffprobe"], env_var: "CVT_BIN_FFPROBE")
    end

    def version
      return @version if defined?(@version)

      @version = probe_version
    end

    def convert(input, output, options = {}, _warnings = [])
      ensure_available!
      from = options["from"].to_s
      to = options["to"].to_s
      unless supported_pair?(from, to)
        raise Cvt::Errors.build(
          "unsupported_conversion",
          "FFmpeg cannot convert #{from} to #{to}",
          hint: "Choose an audio or video output format supported by FFmpeg."
        )
      end

      missing = required_encoders(to).reject { |encoder| encoder_available?(encoder) }
      unless missing.empty?
        raise Cvt::Errors.build(
          "backend_unavailable",
          "FFmpeg is missing required encoder(s): #{missing.join(', ')}",
          hint: "Install an FFmpeg build that includes #{missing.join(', ')} " \
                "or choose another output format."
        )
      end

      Cvt::Shell.run!(build_argv(input, output, options, from, to),
                      timeout: timeout(options))
    rescue Cvt::Error => e
      raise unless e.code == "conversion_failed"

      raise Cvt::Errors.build(
        "conversion_failed",
        e.message,
        hint: "Check that the input is a valid, unprotected media file; " \
              "run with --debug for FFmpeg output.",
        details: e.details
      )
    end

    private

    def supported_pair?(from, to)
      return false if from == to
      return false unless OUTPUT_CODECS.key?(to)

      if AUDIO_FORMATS.include?(from)
        AUDIO_FORMATS.include?(to)
      elsif VIDEO_FORMATS.include?(from)
        VIDEO_FORMATS.include?(to) || AUDIO_FORMATS.include?(to) || to == "gif"
      else
        false
      end
    end

    def required_encoders(to)
      entry = OUTPUT_CODECS.fetch(to)
      [entry[:video], entry[:audio]].compact
    end

    def encoder_available?(encoder)
      encoders && encoders.key?(encoder)
    end

    def encoders
      return @encoders if defined?(@encoders)

      @encoders = probe_encoders
    end

    def probe_version
      return nil unless ffmpeg_path

      result = Cvt::Shell.run([ffmpeg_path, "-version"], timeout: 10)
      return nil unless result.success?

      result.stdout.lines.first.to_s.strip
    rescue StandardError
      nil
    end

    def probe_encoders
      return nil unless ffmpeg_path

      result = Cvt::Shell.run([ffmpeg_path, "-hide_banner", "-encoders"], timeout: 15)
      return nil unless result.success?

      result.stdout.each_line.each_with_object({}) do |line, names|
        name = line[/\A\s*[VAS][A-Z.]{5}\s+(\S+)/, 1]
        names[name] = true if name&.match?(/\A[A-Za-z0-9_-]+\z/)
      end
    rescue StandardError
      nil
    end

    def ensure_available!
      return if available?

      reason = if ffmpeg_path.nil?
                 "ffmpeg binary not found"
               elsif ffprobe_path.nil?
                 "ffprobe binary not found"
               else
                 "ffmpeg failed to run"
               end
      raise Cvt::Errors.build(
        "backend_unavailable",
        "FFmpeg is not available: #{reason}",
        hint: "#{Cvt::Bin.hint('ffmpeg')} Set CVT_BIN_FFMPEG (and CVT_BIN_FFPROBE) " \
              "to override the binary paths."
      )
    end

    def timeout(options)
      Integer(options.fetch("timeout", 0))
    rescue ArgumentError, TypeError
      0
    end

    def build_argv(input, output, options, from, to)
      argv = [ffmpeg_path, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input]
      argv << "-vn" if VIDEO_FORMATS.include?(from) && AUDIO_FORMATS.include?(to)
      argv << "-an" if to == "gif"

      filter = to == "gif" ? gif_filter(options) : scale_filter(options, to)
      argv.concat(["-vf", filter]) if filter
      argv.concat(codec_args(to, options))
      argv << output
    end

    def codec_args(to, options)
      entry = OUTPUT_CODECS.fetch(to)
      return [] if to == "gif"

      bitrate = options["bitrate"].to_s.strip
      if AUDIO_FORMATS.include?(to)
        args = ["-c:a", entry[:audio]]
        if entry[:lossy_audio]
          args.concat(["-b:a", bitrate.empty? ? DEFAULT_AUDIO_BITRATE : bitrate])
        end
        args
      else
        args = ["-c:v", entry[:video], "-c:a", entry[:audio]]
        if bitrate.empty?
          args.concat(["-crf", entry[:crf].to_s]) if entry[:crf]
          # libvpx needs an explicit zero bitrate for constant-quality CRF.
          args.concat(["-b:v", "0"]) if entry[:video] == "libvpx-vp9"
        else
          args.concat(["-b:v", bitrate])
        end
        args
      end
    end

    def scale_filter(options, to)
      return nil unless VIDEO_FORMATS.include?(to)

      width = options["width"]
      height = options["height"]
      return nil if width.nil? && height.nil?

      if width && height
        "scale=#{width}:#{height}:force_original_aspect_ratio=decrease:force_divisible_by=2"
      elsif width
        "scale=#{width}:-2"
      else
        "scale=-2:#{height}"
      end
    end

    def gif_filter(options)
      max_width = [options["width"], GIF_MAX_WIDTH].compact.min
      max_height = options["height"]
      scale = if max_height
                "scale=#{max_width}:#{max_height}:force_original_aspect_ratio=decrease:flags=lanczos"
              else
                "scale='min(#{max_width},iw)':-1:flags=lanczos"
              end
      "fps=#{GIF_FPS},#{scale},split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
    end
  end
end
