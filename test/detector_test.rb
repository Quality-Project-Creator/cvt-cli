# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "cvt"

class DetectorTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/detect", __dir__)

  def setup
    @registry = Cvt::Registry.default
    @detector = Cvt::Detector.new(registry: @registry)
  end

  def fixture(name)
    File.join(FIXTURES, name)
  end

  def test_explicit_from_overrides_magic_and_extension
    result = @detector.detect(fixture("document.pdf"), from: "txt")
    assert_equal "txt", result.id
    assert_empty result.warnings

    result = @detector.detect(fixture("document.pdf"), from: "jpeg")
    assert_equal "jpg", result.id
    assert_empty result.warnings
  end

  def test_every_registered_extension_resolves
    Dir.mktmpdir("cvt-detect") do |dir|
      @registry.formats.each do |format|
        format.extensions.each do |extension|
          path = File.join(dir, "sample.#{extension}")
          File.binwrite(path, "")
          result = @detector.detect(path)
          assert_equal format.id, result.id, "extension #{extension} should resolve to #{format.id}"
        end
      end
    end
  end

  def test_zip_container_disambiguation
    {
      "minimal.docx" => "docx",
      "minimal.xlsx" => "xlsx",
      "minimal.odt" => "odt",
      "minimal.ods" => "ods",
      "minimal.epub" => "epub",
      "minimal.zip" => "zip"
    }.each do |name, expected|
      result = @detector.detect(fixture(name))
      assert_equal expected, result.id, "#{name} should detect as #{expected}"
      assert_empty result.warnings
    end
  end

  def test_gzip_disambiguates_tgz_from_gz
    assert_equal "tgz", @detector.detect(fixture("bundle.tar.gz")).id
    assert_equal "gz", @detector.detect(fixture("plain.gz")).id
  end

  def test_binary_magic_formats
    assert_equal "pdf", @detector.detect(fixture("document.pdf")).id
    assert_equal "tar", @detector.detect(fixture("archive.tar")).id
    assert_equal "xz", @detector.detect(fixture("stream.xz")).id
    assert_equal "bz2", @detector.detect(fixture("stream.bz2")).id
  end

  def test_azw3_uses_extension_to_disambiguate_mobipocket_container
    result = @detector.detect(fixture("minimal.azw3"))
    assert_equal "azw3", result.id
    assert_empty result.warnings
  end

  def test_azw3_to_mobi_has_a_route
    pool = Class.new do
      def available_for?(backend, _from, _to, _requirements = [])
        backend == "calibre"
      end
    end.new

    result = Cvt::Router.new(registry: @registry, pool: pool).route("azw3", "mobi")
    assert result.ok?
    assert_equal [{ "backend" => "calibre", "from" => "azw3", "to" => "mobi" }],
                 result.steps.map(&:to_h)
  end

  def test_binary_magic_wins_over_extension_with_warning
    Dir.mktmpdir("cvt-mismatch") do |dir|
      path = File.join(dir, "disguised.txt")
      File.binwrite(path, File.binread(fixture("document.pdf")))
      result = @detector.detect(path)
      assert_equal "pdf", result.id
      assert_equal 1, result.warnings.size
      assert_equal "format_mismatch", result.warnings.first["code"]
      assert_match(/pdf/, result.warnings.first["message"])
    end
  end

  def test_textual_extension_wins_over_textual_magic
    Dir.mktmpdir("cvt-text-ext") do |dir|
      path = File.join(dir, "payload.txt")
      File.write(path, '{"name":"value"}')
      result = @detector.detect(path)
      assert_equal "txt", result.id
      assert_empty result.warnings
    end
  end

  def test_generic_magic_falls_back_to_extension
    Dir.mktmpdir("cvt-generic") do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "# Heading\n\n- item\n")
      result = @detector.detect(path)
      assert_equal "md", result.id
    end
  end

  def test_text_sniffing
    samples = {
      "json" => '{"name":"value"}',
      "jsonl" => %({"name":"a"}\n{"name":"b"}\n),
      "yaml" => "---\nname: value\nitems:\n  - one\n",
      "toml" => "name = \"value\"\ncount = 2\n",
      "xml" => '<?xml version="1.0"?><root><item>1</item></root>',
      "csv" => "name,age\nAlice,30\nBob,40\n",
      "tsv" => "name\tage\nAlice\t30\nBob\t40\n",
      "srt" => "1\n00:00:01,000 --> 00:00:02,000\nhello\n",
      "vtt" => "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n",
      "ass" => "[Script Info]\nTitle: sample\n\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,hello\n",
      "svg" => '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>',
      "html" => "<!DOCTYPE html><html><body><p>hello</p></body></html>",
      "md" => "# Heading\n\nSome **bold** text.\n\n- item\n"
    }

    Dir.mktmpdir("cvt-sniff") do |dir|
      samples.each do |expected, content|
        path = File.join(dir, "sample.#{expected}.unknown")
        File.write(path, content)
        result = @detector.detect(path)
        assert_equal expected, result.id, "content should sniff as #{expected}"
      end
    end
  end

  def test_csv_with_quoted_comma_is_detected_without_extension
    Dir.mktmpdir("cvt-csv-quoted") do |dir|
      path = File.join(dir, "quoted-comma")
      File.write(path, "name,note\nAlice,\"hello, world\"\nBob,x\n")

      result = @detector.detect(path)

      assert_equal "csv", result.id
    end
  end

  def test_unknown_and_unreadable_inputs_do_not_crash
    assert_nil @detector.detect("/definitely/missing/file").format

    Dir.mktmpdir("cvt-unknown") do |dir|
      binary = File.join(dir, "binary.unknown")
      File.binwrite(binary, "\x00\x01\x02\x03".b)
      assert_nil @detector.detect(binary).format

      text = File.join(dir, "plain.unknown")
      File.write(text, "just prose without structure\n")
      assert_nil @detector.detect(text).format
    end
  end

  def test_extension_also_accepts_aliases
    Dir.mktmpdir("cvt-alias") do |dir|
      path = File.join(dir, "photo.JPEG")
      File.binwrite(path, "")
      assert_equal "jpg", @detector.detect(path).id
    end
  end
end
