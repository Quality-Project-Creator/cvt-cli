# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "base64"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "cvt"

class ImageTest < Minitest::Test
  PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIEAIAAAAb/fWfAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6m" \
    "AAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqCwEGOgHiRFZtAAAAQklEQVQY05XQUQ" \
    "0AIBRC0etmlGcYwzzDaBfLYBetIPyfwSj3YqUoIaYBtqDHP6hneA1VCW0Zk3rAlgFigtIAAM61D5Z2EAM0" \
    "q4gpAAAAAElFTkSuQmCC"
  ALPHA_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAEAgMAAADUn3btAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6m" \
    "AAADqYAAAXcJy6UTwAAAAMUExURf8AAP8AAP8AAP///67Fx2YAAAACdFJOUwiNLUO4rQAAAAFiS0dEAxEMTP" \
    "IAAAAHdElNRQfqCwEGOgHiRFZtAAAAEElEQVQI12OQZMhiWMWQBQAFMQGYkrHRngAAAABJRU5ErkJggg=="
  JPG_BASE64 =
    "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI" \
    "CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQ" \
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAIAAgDAREA" \
    "AhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABgQAAIDAAAAAAAAAAAAAAAAAAABFmOR/8QA" \
    "FQEBAQAAAAAAAAAAAAAAAAAABwj/xAAXEQADAQAAAAAAAAAAAAAAAAAAGGOh/9oADAMBAAIRAxEA" \
    "PwAbT25aOK1xwo5ga6f/2Q=="
  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">' \
        '<rect width="64" height="32" fill="red"/></svg>'

  def backend(id)
    Cvt::Backends.load(id)
  end

  def setup
    %w[vips imagemagick rsvg].each { |id| backend(id) }
  end

  # Windows keeps engine-written files locked for a moment after the call
  # returns, so plain Dir.mktmpdir cleanup can raise EACCES. Retry after GC.
  def with_tmpdir(prefix)
    dir = Dir.mktmpdir(prefix)
    yield dir
  ensure
    remove_tmpdir(dir)
  end

  def remove_tmpdir(dir)
    return unless dir && File.directory?(dir)

    attempts = 0
    begin
      FileUtils.remove_entry(dir)
    rescue Errno::EACCES, Errno::ENOTEMPTY
      raise if (attempts += 1) > 20

      GC.start
      sleep 0.1
      retry
    end
  end

  def fixture(dir, name, base64)
    path = File.join(dir, name)
    File.binwrite(path, Base64.strict_decode64(base64))
    path
  end

  def svg_fixture(dir)
    path = File.join(dir, "sample.svg")
    File.write(path, SVG)
    path
  end

  def options(from, to, extra = {})
    { "from" => from, "to" => to, "quality" => 85, "dpi" => 150, "timeout" => 60 }.merge(extra)
  end

  def warning_codes(warnings)
    warnings.map { |warning| warning["code"] }
  end

  def test_backend_identity_and_lazy_loading
    expectations = {
      "vips" => ["gem", 10, "8.15"],
      "imagemagick" => ["gem+cli", 20, nil],
      "rsvg" => ["cli", 15, nil]
    }
    expectations.each do |id, (kind, priority, _version)|
      instance = backend(id)
      refute_nil instance, "backend #{id} failed to load: #{Cvt::Backends.load_error(id)}"
      assert_equal id, instance.id
      assert_equal kind, instance.kind
      assert_equal priority, instance.priority
    end
    assert_equal ["libvips"], backend("vips").requirements
    assert_equal ["imagemagick"], backend("imagemagick").requirements
    assert_equal ["rsvg-convert"], backend("rsvg").requirements
  end

  def test_route_level_availability_rejects_unrelated_formats
    vips = backend("vips")
    refute vips.available_for?("png", "pdf", []) if vips.available?
    refute vips.available_for?("svg", "png", []) if vips.available?

    imagemagick = backend("imagemagick")
    refute imagemagick.available_for?("png", "pdf", []) if imagemagick.available?
    refute imagemagick.available_for?("svg", "pdf", []) if imagemagick.available?

    rsvg = backend("rsvg")
    refute rsvg.available_for?("png", "png", []) if rsvg.available?
    refute rsvg.available_for?("svg", "jpg", []) if rsvg.available?
  end

  def test_imagemagick_uses_only_magick_on_windows
    calls = []
    Cvt::Bin.stub(:find, proc { |*args| calls << args; nil }) do
      Gem.stub(:win_platform?, true) do
        refute Cvt::ImageMagickBackend.new.available?
      end
    end
    assert_equal "magick", calls.first.first
  end

  def test_imagemagick_searches_magick_then_convert_on_unix
    calls = []
    Cvt::Bin.stub(:find, proc { |*args| calls << args; nil }) do
      Gem.stub(:win_platform?, false) do
        refute Cvt::ImageMagickBackend.new.available?
      end
    end
    assert_equal %w[magick convert], calls.first.first
  end

  def test_rsvg_and_imagemagick_are_unavailable_without_their_binaries
    Cvt::Bin.stub(:find, proc { |*_args| nil }) do
      refute Cvt::RsvgBackend.new.available?
      refute Cvt::ImageMagickBackend.new.available?
    end
  end

  def test_imagemagick_pins_minimagick_to_the_found_binary
    require "mini_magick"

    Dir.mktmpdir("cvt-image") do |dir|
      fake = File.join(dir, Gem.win_platform? ? "magick.exe" : "convert")
      File.write(fake, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, fake) unless Gem.win_platform?

      instance = Cvt::ImageMagickBackend.new
      Cvt::Bin.stub(:find, proc { |*_args| fake }) do
        assert_equal fake, instance.send(:binary)
        tool = instance.send(:new_tool, fake)
        tool.merge!(["image.png", "-resize", "10x10", "out.webp"])
        assert_equal [fake, "image.png", "-resize", "10x10", "out.webp"], tool.command
      end
    end
  end

  def test_quality_option_normalization
    warnings = []
    assert_equal 85, Cvt::Adapters::Image::Options.quality({}, to: "jpg", warnings: warnings)
    assert_empty warnings

    warnings = []
    assert_equal 90, Cvt::Adapters::Image::Options.quality({ "quality" => 90 }, to: "jpg",
                                                           warnings: warnings)
    assert_empty warnings

    warnings = []
    Cvt::Adapters::Image::Options.quality({ "quality" => 90 }, to: "png", warnings: warnings)
    assert_includes warning_codes(warnings), "option_ignored"

    assert_raises(Cvt::Error) do
      Cvt::Adapters::Image::Options.quality({ "quality" => 0 }, to: "jpg")
    end
  end

  def test_dpi_and_page_defaults
    assert_equal 150, Cvt::Adapters::Image::Options.dpi({})
    assert_equal 200, Cvt::Adapters::Image::Options.dpi({ "dpi" => 200 })
    assert_raises(Cvt::Error) { Cvt::Adapters::Image::Options.dpi({ "dpi" => 601 }) }

    assert_equal 1, Cvt::Adapters::Image::Options.page({})
    assert_equal 3, Cvt::Adapters::Image::Options.page({ "page" => 3 })
    assert_raises(Cvt::Error) { Cvt::Adapters::Image::Options.page({ "page" => 0 }) }
  end

  def test_fit_scale_preserves_aspect_and_allows_upscale
    assert_in_delta 0.64, Cvt::Adapters::Image::Options.fit_scale(100, 50, 64, 64)
    assert_in_delta 2.0, Cvt::Adapters::Image::Options.fit_scale(100, 50, 200, nil)
    assert_in_delta 0.5, Cvt::Adapters::Image::Options.fit_scale(100, 100, 50, 400)
    assert_nil Cvt::Adapters::Image::Options.fit_scale(100, 50, nil, nil)
  end

  def test_ico_box_defaults_and_range
    assert_equal [256, 256], Cvt::Adapters::Image::Options.ico_box({})
    assert_equal [16, 16], Cvt::Adapters::Image::Options.ico_box({ "width" => 16, "height" => 16 })
    error = assert_raises(Cvt::Error) do
      Cvt::Adapters::Image::Options.ico_box({ "width" => 300 })
    end
    assert_equal "usage_error", error.code
  end

  def test_png_to_webp_with_vips
    vips = backend("vips")
    skip "libvips is unavailable" unless vips&.available_for?("png", "webp", [])

    with_tmpdir("cvt-image") do |dir|
      input = fixture(dir, "sample.png", PNG_BASE64)
      output = File.join(dir, "out.webp")
      warnings = []
      vips.convert(input, output, options("png", "webp", "quality" => 80), warnings)
      assert File.file?(output)
      assert_equal "RIFF", File.binread(output, 4)
      assert_includes warning_codes(warnings), "metadata_stripped"
    end
  end

  def test_alpha_png_to_jpeg_flattens_and_warns
    vips = backend("vips")
    skip "libvips is unavailable" unless vips&.available_for?("png", "jpg", [])

    with_tmpdir("cvt-image") do |dir|
      input = fixture(dir, "alpha.png", ALPHA_PNG_BASE64)
      output = File.join(dir, "out.jpg")
      warnings = []
      vips.convert(input, output, options("png", "jpg"), warnings)
      assert File.file?(output)
      assert_equal "\xFF\xD8".b, File.binread(output, 2)
      assert_includes warning_codes(warnings), "alpha_flattened"
    end
  end

  def test_png_to_ico_with_imagemagick
    imagemagick = backend("imagemagick")
    skip "ImageMagick is unavailable" unless imagemagick&.available_for?("png", "ico", [])

    Dir.mktmpdir("cvt-image") do |dir|
      input = fixture(dir, "sample.png", PNG_BASE64)
      output = File.join(dir, "out.ico")
      warnings = []
      imagemagick.convert(input, output, options("png", "ico"), warnings)
      assert File.file?(output)
      assert_equal "\x00\x00\x01\x00".b, File.binread(output, 4)
    end
  end

  def test_animated_gif_keeps_first_frame_and_warns
    imagemagick = backend("imagemagick")
    skip "ImageMagick is unavailable" unless imagemagick&.available_for?("gif", "png", [])

    Dir.mktmpdir("cvt-image") do |dir|
      gif = File.join(dir, "animated.gif")
      cli = Cvt::Bin.find(Gem.win_platform? ? "magick" : %w[magick convert])
      skip "ImageMagick CLI is unavailable" unless cli
      Cvt::Shell.run!([cli, "-size", "8x8", "xc:red", "xc:blue", "-delay", "10", gif], timeout: 30)

      output = File.join(dir, "out.png")
      warnings = []
      imagemagick.convert(gif, output, options("gif", "png"), warnings)
      assert File.file?(output)
      assert_includes warning_codes(warnings), "animation_lost"
      refute File.exist?(File.join(dir, "out-1.png")), "should not write extra frames"
    end
  end

  def test_svg_conversions_with_rsvg
    rsvg = backend("rsvg")
    skip "rsvg-convert is unavailable" unless rsvg&.available_for?("svg", "png", [])

    Dir.mktmpdir("cvt-image") do |dir|
      input = svg_fixture(dir)
      png = File.join(dir, "out.png")
      pdf = File.join(dir, "out.pdf")
      rsvg.convert(input, png, options("svg", "png"), [])
      rsvg.convert(input, pdf, options("svg", "pdf"), [])
      assert File.file?(png)
      assert_equal "\x89PNG".b, File.binread(png, 4)
      assert_equal "%PDF".b, File.binread(pdf, 4)
    end
  end

  def test_svg_to_png_falls_back_to_imagemagick
    imagemagick = backend("imagemagick")
    cli = Cvt::Bin.imagemagick
    coder_list = cli ? Cvt::Shell.run([cli, "-list", "format"], timeout: 15).stdout : ""
    skip "ImageMagick SVG input is unavailable" unless imagemagick&.available_for?("svg", "png", []) &&
                                                     coder_list.match?(/^\s+(?:MSVG|SVG)\b/i)

    Dir.mktmpdir("cvt-image") do |dir|
      input = svg_fixture(dir)
      output = File.join(dir, "out.png")
      imagemagick.convert(input, output, options("svg", "png"), [])
      assert File.file?(output)
      assert_equal "\x89PNG".b, File.binread(output, 4)
    end
  end

  def test_jpg_fixture_is_decodable
    Dir.mktmpdir("cvt-image") do |dir|
      path = fixture(dir, "sample.jpg", JPG_BASE64)
      assert_equal "\xFF\xD8".b, File.binread(path, 2)
    end
  end
end
