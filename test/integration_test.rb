# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "base64"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"
require "zip"

require "cvt"

# End-to-end CLI coverage (Task 12). Each conversion test runs `cvt` in a
# subprocess and skips only when its route has no available engine. Setting
# CVT_INTEGRATION=1 is not required: tests run automatically as soon as the
# prerequisite engines are installed, and stay as skips on a bare Ruby host.
class IntegrationTest < Minitest::Test
  EXE = File.expand_path("../exe/cvt", __dir__)
  FIXTURES = File.expand_path("fixtures/detect", __dir__)

  PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIEAIAAAAb/fWfAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6m" \
    "AAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqCwEGOgHiRFZtAAAAQklEQVQY05XQUQ" \
    "0AIBRC0etmlGcYwzzDaBfLYBetIPyfwSj3YqUoIaYBtqDHP6hneA1VCW0Zk3rAlgFigtIAAM61D5Z2EAM0" \
    "q4gpAAAAAElFTkSuQmCC"
  SAMPLE_RATE = 44_100

  def setup
    @dir = Dir.mktmpdir("cvt-integration-")
    @router = Cvt::Router.new
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def path(name)
    File.join(@dir, name)
  end

  def fixture(name, destination)
    FileUtils.cp(File.join(FIXTURES, name), destination)
    destination
  end

  def run_cvt(*args)
    Open3.capture3(RbConfig.ruby, EXE, *args)
  end

  def skip_unless_route(from, to)
    result = @router.route(from, to)
    skip "no available route #{from} -> #{to}: #{result.error&.message}" unless result.ok?
  end

  def convert_success(source, target, *options)
    stdout, stderr, status = run_cvt(source, target, *options)
    assert_equal 0, status.exitstatus, "cvt #{source} -> #{target} failed:\n#{stdout}\n#{stderr}"
    assert_equal "", stderr

    document = YAML.safe_load(stdout)
    assert_equal true, document["ok"]
    refute_nil document["output"], "success document must include output"
    assert File.file?(document["output"]["path"]), "expected output file #{document['output']['path']}"
    document
  end

  def convert_failure(source, target, code, exit_code, *options)
    stdout, stderr, status = run_cvt(source, target, *options)
    assert_equal exit_code, status.exitstatus, "cvt #{source} -> #{target} failed:\n#{stdout}\n#{stderr}"
    assert_equal "", stderr

    document = YAML.safe_load(stdout)
    assert_equal false, document["ok"]
    assert_equal code, document.dig("error", "code")
    document
  end

  def write_csv(target, content = "name,age\nAlice,30\nBob,40\n")
    File.write(target, content)
    target
  end

  def write_png(target)
    File.binwrite(target, Base64.strict_decode64(PNG_BASE64))
    target
  end

  def write_wav(target, seconds: 0.25, frequency: 440)
    samples = (0...(SAMPLE_RATE * seconds).to_i).map do |index|
      (Math.sin(2 * Math::PI * frequency * index / SAMPLE_RATE) * 0.5 * 32_767).round
    end
    data = samples.pack("s<*")
    header = "RIFF" + [36 + data.bytesize].pack("V") + "WAVE" +
             "fmt " + [16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16].pack("VvvVVvv") +
             "data" + [data.bytesize].pack("V")
    File.binwrite(target, header + data)
    target
  end

  def write_mp4(target)
    ffmpeg = Cvt::Bin.find("ffmpeg", env_var: "CVT_BIN_FFMPEG")
    return false unless ffmpeg

    result = Cvt::Shell.run(
      [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
       "-f", "lavfi", "-i", "testsrc=duration=0.5:size=160x120:rate=12",
       "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
       "-c:v", "mpeg4", "-c:a", "aac", "-shortest", target],
      timeout: 60
    )
    result.success? && File.file?(target) && File.size(target).positive?
  end

  def write_zip(target, entries = { "docs/hello.txt" => "hello" })
    Zip::File.open(target, create: true) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { |stream| stream.write(content) }
      end
    end
    target
  end

  # ---------------------------------------------------------------- route wiring

  def test_every_registry_backend_has_a_loadable_adapter
    Cvt::Registry.default.backend_ids.sort.each do |id|
      backend = Cvt::Backends.load(id)
      refute_nil backend, "backend #{id} failed to load: #{Cvt::Backends.load_error(id)}"
      assert_equal id, backend.id
      assert_respond_to backend, :convert
      assert_respond_to backend, :available_for?
    end
  end

  def test_every_registry_route_uses_a_known_backend_and_format_pair
    registry = Cvt::Registry.default
    registry.routes.each do |route|
      refute_nil registry.backend(route.backend), "unknown backend #{route.backend}"
      assert registry.format(route.from), "unknown route source #{route.from}"
      assert registry.format(route.to), "unknown route target #{route.to}"
    end
  end

  # ---------------------------------------------------------------- info commands

  def test_doctor_reports_engine_paths_versions_and_hints
    stdout, stderr, status = run_cvt("--doctor")
    assert_equal 0, status.exitstatus
    assert_equal "", stderr

    document = YAML.safe_load(stdout)
    assert_equal "doctor", document["operation"]
    assert_equal 13, document["backends"].size
    assert_respond_to document["native_dependencies"], :each

    document["backends"].each do |entry|
      assert_equal %w[id kind available version path hint], entry.keys
      if entry["available"]
        assert_equal "", entry["hint"]
        assert_nil entry["path"] if %w[gem native].include?(entry["kind"])
      else
        refute_empty entry["hint"], "backend #{entry['id']} needs an actionable hint"
        assert_match(/Install/, entry["hint"])
      end
      assert entry["path"].nil? || File.executable?(entry["path"]),
             "path must be an executable or null for #{entry['id']}"
    end
  end

  def test_backends_hints_match_doctor_hints
    doctor = YAML.safe_load(run_cvt("--doctor").first)
    backends = YAML.safe_load(run_cvt("--backends").first)
    hints = doctor["backends"].to_h { |entry| [entry["id"], entry["hint"]] }

    backends["backends"].each do |entry|
      assert_equal hints.fetch(entry["id"]), entry["hint"], "hint mismatch for #{entry['id']}"
    end
  end

  def test_version_does_not_load_backend_adapters
    before = Cvt::Backend.implementations.keys
    out = StringIO.new
    err = StringIO.new
    code = Cvt::CLI.run(["--version"], out: out, err: err)

    assert_equal 0, code
    assert_equal "", err.string
    assert_equal before, Cvt::Backend.implementations.keys
  end

  # ---------------------------------------------------------------- conversions

  def test_csv_to_json
    skip_unless_route("csv", "json")
    source = write_csv(path("data.csv"))
    target = path("data.json")
    document = convert_success(source, target)

    assert_equal [{ "backend" => "native_data", "from" => "csv", "to" => "json" }],
                 document["route"]
    rows = JSON.parse(File.read(target))
    assert_equal 2, rows.size
    assert_equal "Alice", rows.first["name"]
    assert_equal "30", rows.first["age"], "CSV cells must stay strings"
  end

  def test_png_to_webp
    skip_unless_route("png", "webp")
    source = write_png(path("photo.png"))
    target = path("photo.webp")
    document = convert_success(source, target)

    assert_equal "webp", document["output"]["format"]
    assert File.size(target).positive?
  end

  def test_png_to_pdf
    skip_unless_route("png", "pdf")
    source = write_png(path("cover.png"))
    target = path("cover.pdf")
    document = convert_success(source, target)

    assert_equal "pdf", document["output"]["format"]
    assert File.size(target).positive?
  end

  def test_pdf_to_png_page_one
    skip_unless_route("png", "pdf")
    skip_unless_route("pdf", "png")

    source = write_png(path("page-source.png"))
    pdf = path("page.pdf")
    convert_success(source, pdf)

    target = path("page1.png")
    document = convert_success(pdf, target, "--page", "1")
    assert_equal 1, document["options"]["page"]
    assert File.size(target).positive?
  end

  def test_wav_to_mp3
    skip_unless_route("wav", "mp3")
    source = write_wav(path("tone.wav"))
    target = path("tone.mp3")
    document = convert_success(source, target)

    assert_equal "mp3", document["output"]["format"]
    assert File.size(target).positive?
  end

  def test_video_with_audio_to_mp3
    skip_unless_route("mp4", "mp3")
    source = path("movie.mp4")
    skip "ffmpeg could not generate the MP4 fixture" unless write_mp4(source)

    target = path("movie.mp3")
    document = convert_success(source, target)

    assert_equal "mp3", document["output"]["format"]
    assert_equal %w[ffmpeg], document["route"].map { |step| step["backend"] }
    assert File.size(target).positive?
  end

  def test_md_to_html
    skip_unless_route("md", "html")
    source = path("notes.md")
    File.write(source, "# Heading\n\nSome **bold** text.\n")
    target = path("notes.html")
    convert_success(source, target)

    html = File.read(target)
    assert_includes html, "<h1"
    assert_includes html, "<strong>bold</strong>"
  end

  def test_md_to_pdf
    skip_unless_route("md", "pdf")
    source = path("notes.md")
    File.write(source, "# Heading\n\nBody text.\n")
    target = path("notes.pdf")
    document = convert_success(source, target)

    assert_equal %w[native_text libreoffice], document["route"].map { |step| step["backend"] }
    assert_includes document["warnings"].map { |warning| warning["code"] }, "multi_step_route"
    assert File.size(target).positive?
  end

  def test_docx_to_pdf
    skip_unless_route("md", "docx")
    skip_unless_route("docx", "pdf")

    source = path("report.md")
    File.write(source, "# Report\n\nParagraph.\n")
    docx = path("report.docx")
    convert_success(source, docx)

    target = path("report.pdf")
    document = convert_success(docx, target)
    assert_equal %w[libreoffice], document["route"].map { |step| step["backend"] }
    assert File.size(target).positive?
  end

  def test_xlsx_to_csv
    skip_unless_route("csv", "xlsx")
    skip_unless_route("xlsx", "csv")

    source = write_csv(path("people.csv"))
    xlsx = path("people.xlsx")
    convert_success(source, xlsx)

    csv_target = path("roundtrip.csv")
    document = convert_success(xlsx, csv_target)

    assert_equal "csv", document["output"]["format"]
    content = File.read(csv_target)
    assert_includes content, "name,age"
    assert_includes content, "Alice,30"
  end

  def test_zip_to_tgz
    skip_unless_route("zip", "tgz")
    source = write_zip(path("bundle.zip"))
    target = path("bundle.tar.gz")
    document = convert_success(source, target)

    assert_equal "tgz", document["output"]["format"]
    assert File.size(target).positive?
  end

  def test_srt_to_vtt
    skip_unless_route("srt", "vtt")
    source = path("captions.srt")
    File.write(source, "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    target = path("captions.vtt")
    convert_success(source, target)

    content = File.read(target)
    assert content.start_with?("WEBVTT")
    assert_includes content, "00:00:01.000 --> 00:00:02.000"
    assert_includes content, "Hello"
  end

  # ---------------------------------------------------------------- error exits

  def test_pdf_to_docx_is_unsupported
    source = fixture("document.pdf", path("document.pdf"))
    convert_failure(source, path("document.docx"), "unsupported_conversion", 3)
    refute File.exist?(path("document.docx"))
  end

  def test_missing_calibre_epub_to_mobi_exits_four
    skip "Calibre is installed; the unavailable path cannot be exercised" if Cvt::Backends.available?("calibre")

    source = fixture("minimal.epub", path("book.epub"))
    document = convert_failure(source, path("book.mobi"), "backend_unavailable", 4)
    assert_includes document.dig("error", "hint"), "calibre"
    refute File.exist?(path("book.mobi"))
  end

  def test_overwrite_exits_six_without_force
    skip_unless_route("csv", "json")
    source = write_csv(path("data.csv"))
    target = path("data.json")
    File.write(target, "original")

    convert_failure(source, target, "output_exists", 6)
    assert_equal "original", File.read(target)
  end

  def test_same_file_exits_six_even_with_force
    skip_unless_route("csv", "json")
    source = write_csv(path("same.csv"))
    convert_failure(source, source, "same_file", 6, "--force")
  end

  def test_dry_run_creates_no_file
    skip_unless_route("csv", "json")
    source = write_csv(path("plan.csv"))
    target = path("plan.json")

    stdout, stderr, status = run_cvt(source, target, "--dry-run")
    assert_equal 0, status.exitstatus
    assert_equal "", stderr

    document = YAML.safe_load(stdout)
    assert_equal true, document["ok"]
    assert_equal "plan", document["operation"]
    refute File.exist?(target)
  end
end
