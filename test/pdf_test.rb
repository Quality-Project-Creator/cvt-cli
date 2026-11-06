# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "base64"
require "minitest/autorun"
require "tmpdir"
require "cvt"

class PdfTest < Minitest::Test
  PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIEAIAAAAb/fWfAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6m" \
    "AAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqCwEGOgHiRFZtAAAAQklEQVQY05XQUQ" \
    "0AIBRC0etmlGcYwzzDaBfLYBetIPyfwSj3YqUoIaYBtqDHP6hneA1VCW0Zk3rAlgFigtIAAM61D5Z2EAM0" \
    "q4gpAAAAAElFTkSuQmCC"
  ALPHA_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAEAgMAAADUn3btAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6m" \
    "AAADqYAAAXcJy6UTwAAAAMUExURf8AAP8AAP8AAP///67Fx2YAAAACdFJOUwiNLUO4rQAAAAFiS0dEAxEMTP" \
    "IAAAAHdElNRQfqCwEGOgHiRFZtAAAAEElEQVQI12OQZMhiWMWQBQAFMQGYkrHRngAAAABJRU5ErkJggg=="
  WIDE_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAIBAMAAAACWGKkAAAAIGNIUk0AAHomAACAhAAA+gAAAIDo" \
    "AAB1MAAA6mAAADqYAAAXcJy6UTwAAAAbUExURf8AANoAJLYASJEAbW0AkUgAtiQA2gAA/////17L" \
    "kPcAAAABYktHRAiG3pV6AAAAB3RJTUUH6gsBBwkwRjNZUAAAACNJREFUCNdjYIABQShgUIICBmMo" \
    "YHCBAoZQKGBIgwKGcigAAE8HDuFGMdREAAAAAElFTkSuQmCC"
  JPG_BASE64 =
    "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI" \
    "CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQ" \
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAIAAgDAREA" \
    "AhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABgQAAIDAAAAAAAAAAAAAAAAAAABFmOR/8QA" \
    "FQEBAQAAAAAAAAAAAAAAAAAABwj/xAAXEQADAQAAAAAAAAAAAAAAAAAAGGOh/9oADAMBAAIRAxEA" \
    "PwAbT25aOK1xwo5ga6f/2Q=="

  def setup
    @pdf = Cvt::Backends.load("pdf")
    refute_nil @pdf, "pdf backend failed to load: #{Cvt::Backends.load_error('pdf')}"
  end

  def fixture(dir, name, base64)
    path = File.join(dir, name)
    File.binwrite(path, Base64.strict_decode64(base64))
    path
  end

  def options(from, to, extra = {})
    { "from" => from, "to" => to, "quality" => 85, "dpi" => 150, "timeout" => 60 }.merge(extra)
  end

  def two_page_pdf(dir, name = "two_pages.pdf")
    require "prawn"
    path = File.join(dir, name)
    document = Prawn::Document.new
    document.text "page one alpha"
    document.start_new_page
    document.text "page two beta"
    document.render_file(path)
    path
  rescue LoadError
    skip "prawn gem is unavailable"
  end

  def page_box(path)
    require "pdf-reader"
    reader = PDF::Reader.new(path)
    media_box = reader.page(1).attributes[:MediaBox]
    [media_box[2].to_f, media_box[3].to_f]
  end

  def page_count(path)
    require "pdf-reader"
    PDF::Reader.new(path).page_count
  end

  def test_backend_identity
    assert_equal "pdf", @pdf.id
    assert_equal "native+cli", @pdf.kind
    assert_equal 10, @pdf.priority
    assert_equal %w[pdf-reader prawn], @pdf.requirements
  end

  def test_route_level_availability
    refute @pdf.available_for?("svg", "pdf", [])
    refute @pdf.available_for?("png", "png", [])
    assert @pdf.available_for?("png", "pdf", []) if prawn_available?
    assert @pdf.available_for?("pdf", "txt", []) if reader_available?
    assert_equal !Cvt::Adapters::Pdf::Poppler.pdftoppm.nil?, @pdf.available_for?("pdf", "png", [])
  end

  def test_dimensions_reader
    Dir.mktmpdir("cvt-pdf") do |dir|
      assert_equal [8, 8, false],
                   Cvt::Adapters::Pdf::Dimensions.read(fixture(dir, "sample.png", PNG_BASE64))
      assert_equal [4, 4, true],
                   Cvt::Adapters::Pdf::Dimensions.read(fixture(dir, "alpha.png", ALPHA_PNG_BASE64))
      assert_equal [16, 8, false],
                   Cvt::Adapters::Pdf::Dimensions.read(fixture(dir, "wide.png", WIDE_PNG_BASE64))
      assert_equal [8, 8, false],
                   Cvt::Adapters::Pdf::Dimensions.read(fixture(dir, "sample.jpg", JPG_BASE64))

      garbage = File.join(dir, "garbage.png")
      File.write(garbage, "not an image")
      assert_raises(Cvt::Error) { Cvt::Adapters::Pdf::Dimensions.read(garbage) }
    end
  end

  def test_png_to_pdf_is_single_portrait_a4_page
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = fixture(dir, "sample.png", PNG_BASE64)
      output = File.join(dir, "out.pdf")
      warnings = []
      @pdf.convert(input, output, options("png", "pdf"), warnings)
      assert_equal "%PDF".b, File.binread(output, 4)
      assert_equal 1, page_count(output)
      assert_in_delta 595.28, page_box(output)[0], 0.1
      assert_in_delta 841.89, page_box(output)[1], 0.1
      assert_empty warnings
    end
  end

  def test_wide_image_uses_landscape_a4
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = fixture(dir, "wide.png", WIDE_PNG_BASE64)
      output = File.join(dir, "out.pdf")
      @pdf.convert(input, output, options("png", "pdf"), [])
      assert_equal 1, page_count(output)
      assert_in_delta 841.89, page_box(output)[0], 0.1
      assert_in_delta 595.28, page_box(output)[1], 0.1
    end
  end

  def test_alpha_png_to_pdf_warns_about_flattening
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = fixture(dir, "alpha.png", ALPHA_PNG_BASE64)
      output = File.join(dir, "out.pdf")
      warnings = []
      @pdf.convert(input, output, options("png", "pdf"), warnings)
      assert File.file?(output)
      assert_includes warnings.map { |warning| warning["code"] }, "alpha_flattened"
    end
  end

  def test_pdf_to_txt_extracts_all_pages
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      output = File.join(dir, "out.txt")
      @pdf.convert(input, output, options("pdf", "txt"), [])
      text = File.read(output, encoding: "UTF-8")
      assert_includes text, "page one alpha"
      assert_includes text, "page two beta"
      refute_includes text, "\r\n"
    end
  end

  def test_pdf_to_txt_honours_page_option
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      output = File.join(dir, "page2.txt")
      @pdf.convert(input, output, options("pdf", "txt", "page" => 2), [])
      text = File.read(output, encoding: "UTF-8")
      assert_includes text, "page two beta"
      refute_includes text, "page one alpha"
    end
  end

  def test_damaged_pdf_fails_without_output
    Dir.mktmpdir("cvt-pdf") do |dir|
      input = File.join(dir, "damaged.pdf")
      File.write(input, "%PDF-1.4\nthis is not a real pdf\n")
      output = File.join(dir, "out.txt")
      error = assert_raises(Cvt::Error) do
        @pdf.convert(input, output, options("pdf", "txt"), [])
      end
      assert_equal "conversion_failed", error.code
      refute File.exist?(output)
    end
  end

  def test_encrypted_pdf_is_input_protected
    qpdf = Cvt::Bin.find("qpdf")
    skip "qpdf is unavailable for building an encrypted fixture" unless qpdf
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      encrypted = File.join(dir, "encrypted.pdf")
      Cvt::Shell.run!([qpdf, "--encrypt", "secret", "secret", "256", "--", input, encrypted],
                      timeout: 30)
      output = File.join(dir, "out.txt")
      error = assert_raises(Cvt::Error) do
        @pdf.convert(encrypted, output, options("pdf", "txt"), [])
      end
      assert_equal "input_protected", error.code
      refute File.exist?(output)
    end
  end

  def test_pdf_rasterizes_page_two_with_poppler
    skip "pdftoppm is unavailable" unless @pdf.available_for?("pdf", "png", [])
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      first = File.join(dir, "page1.png")
      second = File.join(dir, "page2.png")
      @pdf.convert(input, first, options("pdf", "png", "dpi" => 100), [])
      @pdf.convert(input, second, options("pdf", "png", "dpi" => 100, "page" => 2), [])

      assert File.file?(first)
      assert File.file?(second)
      width, height = Cvt::Adapters::Pdf::Dimensions.read(first)
      assert_operator width, :>, 700
      assert_operator height, :>, 1000
      refute_equal File.binread(first), File.binread(second)
      refute File.exist?(File.join(dir, "page-1.png")), "temporary pdftoppm files must not leak"
    end
  end

  def test_pdf_rasterizes_jpg_with_quality
    skip "pdftoppm is unavailable" unless @pdf.available_for?("pdf", "jpg", [])
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      output = File.join(dir, "out.jpg")
      warnings = []
      @pdf.convert(input, output, options("pdf", "jpg", "quality" => 50), warnings)
      assert File.file?(output)
      assert_equal "\xFF\xD8".b, File.binread(output, 2)
    end
  end

  def test_page_above_page_count_fails
    skip "pdftoppm is unavailable" unless @pdf.available_for?("pdf", "png", [])
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      output = File.join(dir, "missing.png")
      error = assert_raises(Cvt::Error) do
        @pdf.convert(input, output, options("pdf", "png", "page" => 4), [])
      end
      assert_equal "conversion_failed", error.code
      refute File.exist?(output)
    end
  end

  def test_vips_pdf_fallback_rasterizes_first_page
    vips = Cvt::Backends.load("vips")
    skip "libvips PDF loading is unavailable" unless vips&.available_for?("pdf", "png", [])
    skip "prawn is unavailable" unless prawn_available?

    Dir.mktmpdir("cvt-pdf") do |dir|
      input = two_page_pdf(dir)
      output = File.join(dir, "vips_page1.png")
      vips.convert(input, output, options("pdf", "png", "dpi" => 100), [])
      assert File.file?(output)
      assert_equal "\x89PNG".b, File.binread(output, 4)
    end
  end

  private

  def prawn_available?
    @pdf.available_for?("png", "pdf", [])
  end

  def reader_available?
    @pdf.available_for?("pdf", "txt", [])
  end
end
