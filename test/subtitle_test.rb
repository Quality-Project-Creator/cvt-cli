# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "cvt"
require "cvt/adapters/subtitle/subtitles"

# Task 11 coverage: the six srt/vtt/ass pairs, the shared cue model, timestamp
# validation, style warnings, and UTF-8 output.
class SubtitleTest < Minitest::Test
  SRT_SAMPLE = <<~SRT
    1
    00:00:01,000 --> 00:00:03,500
    Hello
    World

    2
    00:00:04,000 --> 00:00:06,000
    Second cue
  SRT

  def setup
    @backend = Cvt::Backends.load("native_subtitle")
    refute_nil @backend, "native_subtitle backend must load"
    @dir = Dir.mktmpdir("cvt-subtitle-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def path(name)
    File.join(@dir, name)
  end

  def convert(from, to, content, options = {})
    input = path("input.#{from}")
    output = path("output.#{to}")
    File.binwrite(input, content)
    warnings = []
    @backend.convert(input, output, { "from" => from, "to" => to }.merge(options), warnings)
    [File.binread(output).force_encoding(Encoding::UTF_8), warnings]
  end

  def assert_conversion_error(from, to, content)
    error = assert_raises(Cvt::Error) { convert(from, to, content) }
    assert_equal "conversion_failed", error.code
    assert_equal 7, error.exit_code
    refute_empty error.hint
    error
  end

  def test_availability_covers_all_pairs
    formats = %w[srt vtt ass]
    formats.product(formats).each do |from, to|
      next if from == to

      assert @backend.available_for?(from, to), "#{from} -> #{to} should be available"
    end
    refute @backend.available_for?("srt", "srt")
    refute @backend.available_for?("srt", "txt")
    assert @backend.available?
    assert_match(/srt/, @backend.version.to_s)
    assert_equal "native_subtitle", @backend.id
  end

  def test_srt_to_vtt
    output, warnings = convert("srt", "vtt", SRT_SAMPLE)

    assert output.start_with?("WEBVTT\n\n")
    assert_includes output, "00:00:01.000 --> 00:00:03.500"
    assert_includes output, "Hello\nWorld"
    refute output.include?("\r"), "VTT output must use LF"
    refute output.include?("\uFEFF")
    assert_empty warnings
  end

  def test_vtt_to_srt_and_style_warning
    vtt = <<~VTT
      WEBVTT

      00:00:01.000 --> 00:00:03.500 align:start line:0
      Hello
      World

      00:00:04.000 --> 00:00:06.000
      Second cue
    VTT

    output, warnings = convert("vtt", "srt", vtt)
    assert_includes output, "00:00:01,000 --> 00:00:03,500"
    assert_includes output, "Hello\nWorld"
    assert warnings.any? { |warning| warning["code"] == "style_loss" }
  end

  def test_vtt_signature_sharing_a_block_keeps_the_first_cue
    vtt = "WEBVTT\n00:00:01.000 --> 00:00:02.000\nHi\n\n00:00:04.000 --> 00:00:05.000\nBye\n"

    output, = convert("vtt", "srt", vtt)

    assert_includes output, "00:00:01,000 --> 00:00:02,000"
    assert_includes output, "Hi"
    assert_includes output, "00:00:04,000 --> 00:00:05,000"
    assert_includes output, "Bye"
  end

  def test_vtt_style_block_warning
    vtt = <<~VTT
      WEBVTT

      STYLE
      ::cue { color: red }

      00:00:01.000 --> 00:00:02.000
      Text
    VTT

    _, warnings = convert("vtt", "srt", vtt)
    assert warnings.any? { |warning| warning["code"] == "style_loss" }
  end

  def test_srt_to_ass_to_srt_round_trip
    ass, = convert("srt", "ass", SRT_SAMPLE)
    assert_includes ass, "[Events]"
    assert_includes ass, "Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,Hello\\NWorld"
    refute ass.include?("\r")

    output, warnings = convert("ass", "srt", ass)
    assert_includes output, "Hello\nWorld"
    assert_includes output, "Second cue"
    assert warnings.any? { |warning| warning["code"] == "style_loss" },
           "converting from ASS should report lost styling"
  end

  def test_ass_to_vtt_strips_overrides_and_effects
    ass = <<~ASS
      [Script Info]
      ScriptType: v4.00+

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
      Style: Fancy,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:01.00,0:00:03.00,Fancy,,0,0,0,,{\\i1}Italic{\\i0} text\\Nsecond line
    ASS

    output, warnings = convert("ass", "vtt", ass)
    assert_includes output, "Italic text\nsecond line"
    assert warnings.any? { |warning| warning["code"] == "style_loss" }
  end

  def test_bom_is_tolerated
    output, = convert("srt", "vtt", "\uFEFF#{SRT_SAMPLE}")
    assert output.start_with?("WEBVTT")
    assert_includes output, "Hello"
  end

  def test_hour_timestamps_use_hh_mm_ss
    vtt = <<~VTT
      WEBVTT

      01:02:03.400 --> 01:02:05.000
      Long cue
    VTT
    _, = convert("vtt", "srt", vtt)
    back, = convert("srt", "vtt", File.binread(path("output.srt")))
    assert_includes back, "01:02:03.400 --> 01:02:05.000"
  end

  def test_rejects_end_before_start
    srt = "1\n00:00:03,000 --> 00:00:01,000\nBad\n"
    error = assert_conversion_error("srt", "vtt", srt)
    assert_match(/ends before it starts/i, error.message)
  end

  def test_rejects_overlapping_cues
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:03,000
      First

      2
      00:00:02,000 --> 00:00:04,000
      Second
    SRT
    error = assert_conversion_error("srt", "ass", srt)
    assert_match(/overlaps/i, error.message)
  end

  def test_rejects_invalid_vtt_timestamp
    vtt = "WEBVTT\n\n-00:00:01.000 --> 00:00:02.000\nBad\n"
    error = assert_conversion_error("vtt", "srt", vtt)
    assert_match(/invalid timestamp/i, error.message)
  end

  def test_rejects_vtt_block_without_timestamp
    error = assert_conversion_error("vtt", "srt", "WEBVTT\n\nnot a cue\n")
    assert_match(/without a timestamp/i, error.message)
  end

  def test_rejects_invalid_ass_cue
    ass = <<~ASS
      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:03.00,0:00:01.00,Default,,0,0,0,,Bad
    ASS
    error = assert_conversion_error("ass", "srt", ass)
    assert_match(/ends before it starts/i, error.message)
  end

  def test_empty_subtitle_input_fails
    error = assert_conversion_error("srt", "vtt", "\n")
    assert_match(/No subtitle cues/i, error.message)
  end

  def test_unsupported_pair_reports_unsupported_conversion
    warnings = []
    error = assert_raises(Cvt::Error) do
      @backend.convert(path("missing.srt"), path("out.txt"),
                       { "from" => "srt", "to" => "txt" }, warnings)
    end
    assert_equal "unsupported_conversion", error.code
    assert_equal 3, error.exit_code
  end
end
