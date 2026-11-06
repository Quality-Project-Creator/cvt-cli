# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "json"
require "minitest/autorun"
require "tmpdir"
require "cvt"

class MediaTest < Minitest::Test
  SAMPLE_RATE = 44_100

  def backend
    Cvt::Backends.load("ffmpeg")
    Cvt::Backend.implementation("ffmpeg").new
  end

  def with_env(values)
    saved = {}
    values.each do |key, value|
      saved[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def write_script(directory, name, body)
    path = File.join(directory, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  # Minimal 16-bit mono PCM WAV so no fixture files are needed.
  def write_wav(path, seconds: 0.25, frequency: 440)
    samples = (0...(SAMPLE_RATE * seconds).to_i).map do |index|
      (Math.sin(2 * Math::PI * frequency * index / SAMPLE_RATE) * 0.5 * 32_767).round
    end
    data = samples.pack("s<*")
    header = "RIFF" + [36 + data.bytesize].pack("V") + "WAVE" +
             "fmt " + [16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16].pack("VvvVVvv") +
             "data" + [data.bytesize].pack("V")
    File.binwrite(path, header + data)
  end

  def with_fake_ffmpeg(encoders: %w[flac mpeg4], ffprobe: true)
    skip "POSIX shell scripts are required to fake FFmpeg" if Gem.win_platform?

    Dir.mktmpdir("cvt-fake-ffmpeg") do |dir|
      listing = encoders.map do |name|
        kind = name == "mpeg4" ? "V....D" : "A....D"
        kind + "  " + name
      end.join("\n")
      ffmpeg = write_script(dir, "ffmpeg", <<~SH)
        #!/bin/sh
        case " $* " in
          *" -version "*) echo "ffmpeg version 0.0.0-fake"; exit 0 ;;
          *" -encoders "*) printf 'Encoders:\\n%s\\n' "#{listing}"; exit 0 ;;
        esac
        exit 1
      SH
      probe = if ffprobe
                write_script(dir, "ffprobe", "#!/bin/sh\nexit 0\n")
              else
                File.join(dir, "missing-ffprobe")
              end

      with_env("PATH" => dir, "CVT_BIN_FFMPEG" => ffmpeg, "CVT_BIN_FFPROBE" => probe) do
        yield
      end
    end
  end

  def probe(backend, path)
    result = Cvt::Shell.run(
      [backend.ffprobe_path, "-hide_banner", "-loglevel", "error",
       "-show_entries", "stream=codec_name,codec_type,width,height",
       "-of", "json", path],
      timeout: 30
    )
    flunk "ffprobe failed: #{result.stderr}" unless result.success?

    JSON.parse(result.stdout)
  end

  def build_mp4_fixture(ffmpeg_path, path)
    result = Cvt::Shell.run(
      [ffmpeg_path, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
       "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=12",
       "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
       "-c:v", "mpeg4", "-c:a", "aac", "-shortest", path],
      timeout: 60
    )
    result.success? && File.file?(path) && File.size(path).positive?
  end

  def with_mp4_fixture(backend)
    Dir.mktmpdir("cvt-media") do |dir|
      input = File.join(dir, "source.mp4")
      skip "could not generate an MP4 fixture with ffmpeg" unless build_mp4_fixture(backend.ffmpeg_path, input)

      yield input, dir
    end
  end

  def test_backend_identity
    instance = backend
    assert_equal "ffmpeg", instance.id
    assert_equal "cli", instance.kind
    assert_equal %w[ffmpeg ffprobe], instance.requirements
  end

  def test_output_codec_map_matches_spec
    expected = {
      "mp3" => [nil, "libmp3lame"],
      "wav" => [nil, "pcm_s16le"],
      "flac" => [nil, "flac"],
      "ogg" => [nil, "libvorbis"],
      "opus" => [nil, "libopus"],
      "aac" => [nil, "aac"],
      "m4a" => [nil, "aac"],
      "aiff" => [nil, "pcm_s16be"],
      "mp4" => ["libx264", "aac"],
      "m4v" => ["libx264", "aac"],
      "webm" => ["libvpx-vp9", "libopus"],
      "mkv" => ["libx264", "aac"],
      "mov" => ["libx264", "aac"],
      "avi" => ["mpeg4", "libmp3lame"],
      "gif" => [nil, nil]
    }

    expected.each do |target, (video, audio)|
      entry = Cvt::FFmpegBackend::OUTPUT_CODECS.fetch(target)
      video.nil? ? assert_nil(entry[:video], "#{target} video encoder")
                  : assert_equal(video, entry[:video], "#{target} video encoder")
      audio.nil? ? assert_nil(entry[:audio], "#{target} audio encoder")
                  : assert_equal(audio, entry[:audio], "#{target} audio encoder")
    end
    assert_equal expected.keys.sort, Cvt::FFmpegBackend::OUTPUT_CODECS.keys.sort
  end

  def test_codec_bitrate_and_scale_arguments_offline
    instance = backend

    assert_equal %w[-c:a libmp3lame -b:a 192k], instance.send(:codec_args, "mp3", {})
    assert_equal %w[-c:a libmp3lame -b:a 2M],
                 instance.send(:codec_args, "mp3", { "bitrate" => "2M" })
    assert_equal %w[-c:a pcm_s16le], instance.send(:codec_args, "wav", {})
    assert_equal %w[-c:v libx264 -c:a aac -crf 23],
                 instance.send(:codec_args, "mp4", {})
    assert_equal %w[-c:v libx264 -c:a aac -b:v 2M],
                 instance.send(:codec_args, "mp4", { "bitrate" => "2M" })
    assert_includes instance.send(:codec_args, "webm", {}), "32"

    assert_equal "scale=100:-2", instance.send(:scale_filter, { "width" => 100 }, "mp4")
    assert_equal "scale=-2:80", instance.send(:scale_filter, { "height" => 80 }, "mp4")
    assert_includes instance.send(:scale_filter, { "width" => 100, "height" => 80 }, "mp4"),
                    "force_original_aspect_ratio=decrease"
    assert_nil instance.send(:scale_filter, { "width" => 100 }, "mp3")
  end

  def test_every_ffmpeg_registry_route_matches_backend_availability
    instance = backend
    registry = Cvt::Registry.default
    routes = registry.routes.select { |route| route.backend == "ffmpeg" }
    assert_equal 140, routes.size

    counts = routes.group_by do |route|
      [registry.format(route.from).category, registry.format(route.to).category]
    end.transform_values(&:size)
    assert_equal({ %w[audio audio] => 56, %w[video video] => 30,
                   %w[video audio] => 48, %w[video image] => 6 }, counts)

    routes.each do |route|
      available = instance.available_for?(route.from, route.to, route.requirements)
      if instance.available?
        assert available, "#{route.from}->#{route.to} should be available"
      else
        refute available, "#{route.from}->#{route.to} must not claim to be available"
      end
    end
    refute instance.available_for?("wav", "gif")
  end

  def test_unavailable_without_ffmpeg
    with_env("PATH" => "", "CVT_BIN_FFMPEG" => nil, "CVT_BIN_FFPROBE" => nil) do
      instance = backend
      refute instance.available?
      assert_nil instance.version
      refute instance.available_for?("wav", "mp3")

      Dir.mktmpdir("cvt-media") do |dir|
        input = File.join(dir, "input.wav")
        output = File.join(dir, "output.mp3")
        write_wav(input)

        error = assert_raises(Cvt::Error) do
          instance.convert(input, output, { "from" => "wav", "to" => "mp3", "timeout" => 5 }, [])
        end
        assert_equal "backend_unavailable", error.code
        assert_equal 4, error.exit_code
        assert_includes error.hint, "FFmpeg"
        refute File.exist?(output)
      end
    end
  end

  def test_missing_ffprobe_makes_backend_unavailable
    with_fake_ffmpeg(encoders: %w[flac], ffprobe: false) do
      instance = backend
      refute instance.available?

      error = assert_raises(Cvt::Error) do
        instance.convert("input.wav", "output.mp3", { "from" => "wav", "to" => "mp3" }, [])
      end
      assert_equal "backend_unavailable", error.code
      assert_includes error.message, "ffprobe"
    end
  end

  def test_encoder_gate_rejects_missing_encoders
    with_fake_ffmpeg(encoders: %w[flac mpeg4]) do
      instance = backend
      assert instance.available?
      assert_match(/ffmpeg version/, instance.version)

      assert instance.available_for?("wav", "flac")
      assert instance.available_for?("mp4", "gif")
      refute instance.available_for?("wav", "mp3")
      refute instance.available_for?("mp4", "webm")
      refute instance.available_for?("wav", "gif")

      Dir.mktmpdir("cvt-media") do |dir|
        input = File.join(dir, "input.wav")
        output = File.join(dir, "output.mp3")
        write_wav(input)

        error = assert_raises(Cvt::Error) do
          instance.convert(input, output, { "from" => "wav", "to" => "mp3" }, [])
        end
        assert_equal "backend_unavailable", error.code
        assert_includes error.message, "libmp3lame"
        refute File.exist?(output)
      end
    end
  end

  def test_wav_to_mp3
    instance = backend
    skip "ffmpeg with libmp3lame is required" unless instance.available_for?("wav", "mp3")

    Dir.mktmpdir("cvt-media") do |dir|
      input = File.join(dir, "input.wav")
      output = File.join(dir, "output.mp3")
      write_wav(input)

      instance.convert(input, output, { "from" => "wav", "to" => "mp3", "timeout" => 60 }, [])
      assert File.file?(output)
      assert_operator File.size(output), :>, 0
      assert_equal "mp3", probe(instance, output).fetch("streams").first["codec_name"]
    end
  end

  def test_mp4_to_mp3_drops_the_video_stream
    instance = backend
    skip "ffmpeg with libmp3lame is required" unless instance.available_for?("mp4", "mp3")

    with_mp4_fixture(instance) do |input, dir|
      output = File.join(dir, "output.mp3")
      instance.convert(input, output, { "from" => "mp4", "to" => "mp3", "timeout" => 60 }, [])

      assert File.file?(output)
      streams = probe(instance, output).fetch("streams")
      assert_equal ["audio"], streams.map { |stream| stream["codec_type"] }
      assert_equal "mp3", streams.first["codec_name"]
    end
  end

  def test_mp4_to_gif_is_capped_and_palette_encoded
    instance = backend
    skip "ffmpeg is not installed" unless instance.available?

    with_mp4_fixture(instance) do |input, dir|
      output = File.join(dir, "output.gif")
      instance.convert(input, output, { "from" => "mp4", "to" => "gif", "timeout" => 60 }, [])

      assert File.file?(output)
      stream = probe(instance, output).fetch("streams").first
      assert_equal "gif", stream["codec_name"]
      assert_operator stream["width"], :<=, Cvt::FFmpegBackend::GIF_MAX_WIDTH
    end
  end

  def test_corrupt_input_reports_conversion_failed_with_stderr
    instance = backend
    skip "ffmpeg is not installed" unless instance.available?

    Dir.mktmpdir("cvt-media") do |dir|
      input = File.join(dir, "broken.mp3")
      output = File.join(dir, "output.wav")
      File.binwrite(input, "\x00not a media stream")

      error = assert_raises(Cvt::Error) do
        instance.convert(input, output, { "from" => "mp3", "to" => "wav", "timeout" => 30 }, [])
      end
      assert_equal "conversion_failed", error.code
      assert_equal 7, error.exit_code
      assert_includes error.hint, "valid"
      assert_kind_of Hash, error.details
      refute_empty error.details["stderr"].to_s
    end
  end
end
