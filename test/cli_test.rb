# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"
require "cvt"

class CliTest < Minitest::Test
  EXE = File.expand_path("../exe/cvt", __dir__)

  class FakeBackend
    attr_reader :id, :last_options

    def initialize(id, behavior: :copy)
      @id = id
      @behavior = behavior
    end

    def version
      "fake-1.0"
    end

    def convert(input, output, options, _warnings)
      @last_options = options
      if @behavior == :timeout
        result = Cvt::Shell.run([RbConfig.ruby, "-e", "sleep 2"], timeout: 0.2)
        if result.timed_out?
          raise Cvt::Errors.build("timeout", "External engine timed out",
                                  hint: "Increase --timeout.",
                                  details: { "stderr" => Cvt::Shell.truncate(result.stderr) })
        end
      end
      File.binwrite(output, File.binread(input))
    end
  end

  class FakePool
    attr_reader :backends

    def initialize(ids, behavior: :copy)
      @backends = Array(ids).each_with_object({}) do |id, hash|
        hash[id.to_s] = FakeBackend.new(id.to_s, behavior: behavior)
      end
    end

    def available_for?(backend, _from, _to, _requirements = [])
      @backends.key?(backend.to_s)
    end

    def available?(backend)
      @backends.key?(backend.to_s)
    end

    def load(backend)
      @backends[backend.to_s]
    end
  end

  def run_exe(*args)
    Open3.capture3(RbConfig.ruby, EXE, *args)
  end

  # libvips reports missing optional modules straight to fd 2; those GLib
  # warnings are engine diagnostics, not CVT output.
  def clean_stderr(stderr)
    stderr.lines.reject { |line| line.match?(/\(process:\d+\): .*-WARNING \*\*:/) }.join.strip
  end

  def run_cli(args, pool: Cvt::Backends)
    out = StringIO.new
    err = StringIO.new
    code = Cvt::CLI.run(args, out: out, err: err, pool: pool)
    [code, out.string, err.string]
  end

  def parse_yaml(output)
    YAML.safe_load(output)
  end

  def write_csv(path, content = "name,age\nAlice,30\n")
    File.write(path, content)
    path
  end

  # --- subprocess CLI contract -------------------------------------------------

  def test_help_is_plain_text_english_and_exits_zero
    stdout, stderr, status = run_exe("--help")
    assert_equal 0, status.exitstatus
    assert_includes stdout, "Usage: cvt SOURCE TARGET"
    assert_includes stdout, "--quality"
    refute stdout.start_with?("ok:")
    assert_equal "", clean_stderr(stderr)
  end

  def test_no_arguments_prints_help_and_exits_two
    stdout, stderr, status = run_exe
    assert_equal 2, status.exitstatus
    assert_includes stdout, "Usage:"
    assert_equal "", clean_stderr(stderr)
  end

  def test_version_yaml
    stdout, stderr, status = run_exe("--version")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal true, document["ok"]
    assert_equal "0.1.0-beta", document["version"]
    assert_equal "version", document["operation"]
    assert_equal RUBY_VERSION, document["ruby"]
    refute_nil document["platform"]
    assert_equal "", clean_stderr(stderr)
  end

  def test_formats_lists_all_56_without_adapters
    stdout, stderr, status = run_exe("--formats")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal true, document["ok"]
    assert_equal "formats", document["operation"]
    assert_equal 56, document["count"]
    assert_equal 56, document["formats"].size

    document["formats"].each do |entry|
      assert_equal %w[id category extensions mime aliases read write available backends],
                   entry.keys
      assert_equal true, entry["read"] || entry["write"]
    end

    svg = document["formats"].find { |entry| entry["id"] == "svg" }
    assert_equal true, svg["read"]
    assert_equal false, svg["write"]
    assert_equal "", clean_stderr(stderr)
  end

  def test_formats_format_detail_resolves_alias
    stdout, _stderr, status = run_exe("--formats", "--format", "jpeg")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "format", document["operation"]
    assert_equal "jpg", document["format"]["id"]
    assert_includes document["format"]["aliases"], "jpeg"
    assert_equal "image/jpeg", document["format"]["mime"]
  end

  def test_formats_unknown_format_uses_did_you_mean
    stdout, _stderr, status = run_exe("--formats", "--format", "jepg")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "unknown_format", document["error"]["code"]
    assert_includes document["error"]["hint"], "jpg"
  end

  def test_formats_category_filter
    stdout, _stderr, status = run_exe("--formats", "--category", "image")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal 12, document["count"]
    assert document["formats"].all? { |entry| entry["category"] == "image" }
  end

  def test_formats_unknown_category_is_a_usage_error
    stdout, _stderr, status = run_exe("--formats", "--category", "imagee")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "usage_error", document["error"]["code"]
    assert_includes document["error"]["hint"], "image"
  end

  def test_backends_lists_thirteen
    stdout, stderr, status = run_exe("--backends")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "backends", document["operation"]
    assert_equal 13, document["count"]
    ids = document["backends"].map { |entry| entry["id"] }
    assert_equal Cvt::Registry.default.backend_ids.sort, ids

    document["backends"].each do |entry|
      assert_equal %w[id kind available version reads writes hint], entry.keys
      refute_nil entry["reads"]
      refute_nil entry["writes"]
    end
    assert_equal "", clean_stderr(stderr)
  end

  def test_backends_available_filter
    stdout, _stderr, status = run_exe("--backends", "--available")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert document["backends"].all? { |entry| entry["available"] }
    assert_equal document["backends"].size, document["count"]
  end

  def test_doctor_reports_environment_and_backends
    stdout, stderr, status = run_exe("--doctor")
    assert_equal 0, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "doctor", document["operation"]
    assert_equal RUBY_VERSION, document["ruby"]
    refute_nil document["platform"]
    assert_equal 56, document["registry"]["formats"]
    assert_equal 13, document["registry"]["backends"]
    assert_equal 13, document["backends"].size
    assert_kind_of Integer, document["available_formats"]
    marcel = document["native_dependencies"].find { |entry| entry["name"] == "marcel" }
    refute_nil marcel, "marcel must be reported as a native dependency"
    assert_equal true, marcel["available"]
    refute_nil marcel["version"]
    assert_equal "", clean_stderr(stderr)
  end

  def test_unknown_option_is_a_usage_error_yaml
    stdout, stderr, status = run_exe("--nope")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "usage_error", document["error"]["code"]
    assert_includes document["error"]["hint"], "--help"
    assert_equal "", clean_stderr(stderr)
  end

  def test_information_options_cannot_mix_with_conversion_arguments
    stdout, _stderr, status = run_exe("--formats", "notes.md")
    assert_equal 2, status.exitstatus
    assert_equal "usage_error", parse_yaml(stdout)["error"]["code"]
  end

  def test_available_requires_backends
    stdout, _stderr, status = run_exe("--available")
    assert_equal 2, status.exitstatus
    assert_equal "usage_error", parse_yaml(stdout)["error"]["code"]
  end

  def test_format_requires_formats
    stdout, _stderr, status = run_exe("--format", "jpg")
    assert_equal 2, status.exitstatus
    assert_equal "usage_error", parse_yaml(stdout)["error"]["code"]
  end

  def test_unknown_to_format
    stdout, _stderr, status = run_exe("a.csv", "--to", "jepg")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "unknown_format", document["error"]["code"]
    assert_includes document["error"]["hint"], "jpg"
  end

  def test_unknown_backend
    stdout, _stderr, status = run_exe("a.csv", "b.json", "--backend", "nope")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "unknown_backend", document["error"]["code"]
    assert_includes document["error"]["hint"], "backends"
  end

  def test_target_and_to_mismatch_is_a_usage_error
    stdout, _stderr, status = run_exe("a.csv", "b.png", "--to", "jpg")
    assert_equal 2, status.exitstatus
    document = parse_yaml(stdout)
    assert_equal "usage_error", document["error"]["code"]
    assert_includes document["error"]["message"], "does not match"
  end

  def test_quiet_suppresses_information_success_only
    stdout, _stderr, status = run_exe("--formats", "--quiet")
    assert_equal 0, status.exitstatus
    assert_equal "", stdout

    stdout, _stderr, status = run_exe("--formats", "--format", "jepg", "--quiet")
    assert_equal 2, status.exitstatus
    assert_equal "unknown_format", parse_yaml(stdout)["error"]["code"]
  end

  # --- conversion through an injected fake pool --------------------------------

  def test_conversion_success_and_quiet
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = File.join(dir, "data.json")
      code, output, stderr = run_cli([source, target], pool: FakePool.new(%w[native_data]))
      assert_equal 0, code
      document = parse_yaml(output)
      assert_equal true, document["ok"]
      assert_equal "convert", document["operation"]
      assert_equal %w[ok version operation input output route options timing warnings],
                   document.keys
      assert_equal "csv", document["input"]["format"]
      assert_equal "json", document["output"]["format"]
      assert_equal [{ "backend" => "native_data", "from" => "csv", "to" => "json" }],
                   document["route"]
      assert_equal "", clean_stderr(stderr)
      assert File.exist?(target)

      code, output, = run_cli([source, target, "--force", "--quiet"],
                              pool: FakePool.new(%w[native_data]))
      assert_equal 0, code
      assert_equal "", output
    end
  end

  def test_conversion_overwrite_protection
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = write_csv(File.join(dir, "data.json"), "original")
      code, output, = run_cli([source, target], pool: FakePool.new(%w[native_data]))
      assert_equal 6, code
      document = parse_yaml(output)
      assert_equal %w[ok version operation error input output warnings], document.keys
      assert_equal "output_exists", document["error"]["code"]
      assert_equal 6, document["error"]["exit_code"]
      assert_equal "original", File.read(target)
    end
  end

  def test_conversion_same_file_is_rejected_even_with_force
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      code, output, = run_cli([source, source, "--force"], pool: FakePool.new(%w[native_data]))
      assert_equal 6, code
      assert_equal "same_file", parse_yaml(output)["error"]["code"]
    end
  end

  def test_dry_run_writes_nothing
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = File.join(dir, "data.json")
      code, output, = run_cli([source, target, "--dry-run"], pool: FakePool.new(%w[native_data]))
      assert_equal 0, code
      document = parse_yaml(output)
      assert_equal "plan", document["operation"]
      assert_equal true, document["ok"]
      refute document["output"].key?("bytes")
      refute File.exist?(target)
    end
  end

  def test_auto_naming_with_to
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "notes.csv"))
      code, output, = run_cli([source, "--to", "json"], pool: FakePool.new(%w[native_data]))
      assert_equal 0, code
      document = parse_yaml(output)
      assert_equal File.join(dir, "notes.json"), document["output"]["path"]
      assert File.exist?(File.join(dir, "notes.json"))
    end
  end

  def test_input_not_found
    Dir.mktmpdir("cvt-cli") do |dir|
      code, output, = run_cli([File.join(dir, "missing.csv"), File.join(dir, "out.json")],
                              pool: FakePool.new(%w[native_data]))
      assert_equal 5, code
      assert_equal "input_not_found", parse_yaml(output)["error"]["code"]
    end
  end

  def test_format_undetected
    Dir.mktmpdir("cvt-cli") do |dir|
      source = File.join(dir, "blob")
      File.binwrite(source, "\x00\x01\x02\x03".b)
      code, output, = run_cli([source, File.join(dir, "out.json")],
                              pool: FakePool.new(%w[native_data]))
      assert_equal 5, code
      assert_equal "format_undetected", parse_yaml(output)["error"]["code"]
    end
  end

  def test_output_unwritable_when_parent_missing
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      code, output, = run_cli([source, File.join(dir, "missing", "out.json")],
                              pool: FakePool.new(%w[native_data]))
      assert_equal 6, code
      assert_equal "output_unwritable", parse_yaml(output)["error"]["code"]
    end
  end

  def test_backend_unavailable
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      code, output, = run_cli([source, File.join(dir, "out.json")], pool: FakePool.new([]))
      assert_equal 4, code
      document = parse_yaml(output)
      assert_equal "backend_unavailable", document["error"]["code"]
      assert_includes document["error"]["hint"], "--doctor"
    end
  end

  def test_timeout_cleans_up_without_partial_output
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = File.join(dir, "out.json")
      code, output, = run_cli([source, target, "--timeout", "1"],
                              pool: FakePool.new(%w[native_data], behavior: :timeout))
      assert_equal 8, code
      document = parse_yaml(output)
      assert_equal "timeout", document["error"]["code"]
      assert_equal 8, document["error"]["exit_code"]
      refute File.exist?(target)
      leftovers = Dir.children(dir).select { |name| name.start_with?(".cvt-") }
      assert_empty leftovers
    end
  end

  def test_two_step_route_and_warnings
    Dir.mktmpdir("cvt-cli") do |dir|
      source = File.join(dir, "report.docx")
      File.binwrite(source, File.binread(File.expand_path("fixtures/detect/minimal.docx", __dir__)))
      target = File.join(dir, "report.png")
      pool = FakePool.new(%w[libreoffice pdf])
      code, output, = run_cli([source, target], pool: pool)
      assert_equal 0, code
      document = parse_yaml(output)
      assert_equal %w[libreoffice pdf], document["route"].map { |step| step["backend"] }
      codes = document["warnings"].map { |warning| warning["code"] }
      assert_includes codes, "multi_step_route"
      assert_equal({ "from" => "docx", "to" => "pdf" }, pool.backends["libreoffice"].last_options
                                                            .slice("from", "to"))
      assert_equal({ "from" => "pdf", "to" => "png" }, pool.backends["pdf"].last_options
                                                         .slice("from", "to"))
      assert File.exist?(target)
      leftovers = Dir.children(dir).select { |name| name.start_with?(".cvt-") }
      assert_empty leftovers
    end
  end

  def test_options_are_echoed_from_provided_values
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = File.join(dir, "data.json")
      code, output, = run_cli([source, target, "--quality", "80"],
                              pool: FakePool.new(%w[native_data]))
      assert_equal 0, code
      document = parse_yaml(output)
      assert_equal 80, document["options"]["quality"]
      assert_equal [], document["warnings"]
    end
  end

  def test_backend_receives_step_context_but_yaml_does_not
    Dir.mktmpdir("cvt-cli") do |dir|
      source = write_csv(File.join(dir, "data.csv"))
      target = File.join(dir, "data.json")
      pool = FakePool.new(%w[native_data])
      code, output, = run_cli([source, target], pool: pool)
      assert_equal 0, code

      seen = pool.backends["native_data"].last_options
      assert_equal "csv", seen["from"]
      assert_equal "json", seen["to"]

      document = parse_yaml(output)
      refute document["options"].key?("from")
      refute document["options"].key?("to")
    end
  end
end
