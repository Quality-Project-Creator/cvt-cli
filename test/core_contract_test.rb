# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "yaml"
require "cvt"

class CoreContractTest < Minitest::Test
  EXIT_CODE_TABLE = {
    "usage_error" => 2,
    "unknown_format" => 2,
    "unknown_backend" => 2,
    "unsupported_conversion" => 3,
    "backend_unavailable" => 4,
    "input_not_found" => 5,
    "input_unreadable" => 5,
    "format_undetected" => 5,
    "unsafe_archive" => 5,
    "input_protected" => 5,
    "output_exists" => 6,
    "output_unwritable" => 6,
    "same_file" => 6,
    "conversion_failed" => 7,
    "timeout" => 8,
    "interrupted" => 130,
    "internal_error" => 1
  }.freeze

  def test_version
    assert_equal "0.0.1-beta", Cvt::VERSION
  end

  def test_error_codes_and_exit_codes
    assert_equal EXIT_CODE_TABLE, Cvt::Errors::EXIT_CODES
    EXIT_CODE_TABLE.each do |code, exit_code|
      assert_equal exit_code, Cvt::Errors.exit_code(code)
      assert_equal exit_code, Cvt::Error.new(code: code, message: "x").exit_code
    end
    assert Cvt::Errors.known?("timeout")
    refute Cvt::Errors.known?("not_a_code")
    assert_raises(ArgumentError) { Cvt::Errors.exit_code("not_a_code") }
  end

  def test_error_defaults
    error = Cvt::Error.new(code: "conversion_failed", message: "Engine failed")
    assert_equal "", error.hint
    assert_equal 7, error.exit_code
    assert_nil error.details
    assert_equal %w[code message hint exit_code], error.to_h.keys
  end

  def test_success_document_schema
    yaml = Cvt::YAMLOutput.success(
      operation: "convert",
      input: Cvt::YAMLOutput.input(path: "photo.png", format: "png", bytes: 12_345),
      output: Cvt::YAMLOutput.output(path: "photo.webp", format: "webp", bytes: 6789),
      route: [Cvt::Route.new(backend: "vips", from: "png", to: "webp")],
      options: { "quality" => 85 },
      timing: { "total_ms" => 42 },
      warnings: [{ "code" => "metadata_stripped", "message" => "Metadata removed" }]
    )

    document = YAML.safe_load(yaml)
    assert_equal %w[ok version operation input output route options timing warnings], document.keys
    assert_equal true, document["ok"]
    assert_equal "0.0.1-beta", document["version"]
    assert_equal "convert", document["operation"]
    assert_equal %w[path format bytes], document["input"].keys
    assert_equal %w[path format bytes], document["output"].keys
    assert_equal [{ "backend" => "vips", "from" => "png", "to" => "webp" }], document["route"]
    assert_equal "metadata_stripped", document["warnings"][0]["code"]

    refute yaml.start_with?("---")
    refute_includes yaml, "\r"
    refute_match(/!ruby/, yaml)
    assert_equal "\n", yaml[-1]
  end

  def test_failure_document_schema
    yaml = Cvt::YAMLOutput.failure(
      operation: "convert",
      error: Cvt::Error.new(
        code: "output_exists",
        message: "Output file already exists: photo.webp",
        hint: "Pass --force to overwrite it."
      ),
      input: Cvt::YAMLOutput.input(path: "photo.png", format: "png"),
      output: Cvt::YAMLOutput.output(path: "photo.webp", format: "webp")
    )

    document = YAML.safe_load(yaml)
    assert_equal %w[ok version operation error input output warnings], document.keys
    assert_equal false, document["ok"]
    assert_equal %w[code message hint exit_code], document["error"].keys
    assert_equal "output_exists", document["error"]["code"]
    assert_equal 6, document["error"]["exit_code"]
    assert_equal [], document["warnings"]
    refute yaml.start_with?("---")
  end

  def test_failure_accepts_hash_and_empty_hint
    yaml = Cvt::YAMLOutput.failure(
      operation: "convert",
      error: { "code" => "backend_unavailable", "message" => "Missing engine" }
    )
    document = YAML.safe_load(yaml)
    assert_equal "", document["error"]["hint"]
    assert_equal 4, document["error"]["exit_code"]
    refute document.key?("input")
  end

  def test_warnings_are_normalized
    yaml = Cvt::YAMLOutput.success(
      operation: "convert",
      warnings: [{ code: "multi_step_route", message: "Two steps" }]
    )
    document = YAML.safe_load(yaml)
    assert_equal [{ "code" => "multi_step_route", "message" => "Two steps" }],
                 document["warnings"]
  end

  def test_yaml_rejects_symbol_keys
    assert_raises(Cvt::YAMLOutput::InvalidDocument) do
      Cvt::YAMLOutput.dump({ foo: "bar" })
    end
  end

  def test_yaml_rejects_symbols_and_objects
    assert_raises(Cvt::YAMLOutput::InvalidDocument) do
      Cvt::YAMLOutput.dump({ "value" => :symbol })
    end
    assert_raises(Cvt::YAMLOutput::InvalidDocument) do
      Cvt::YAMLOutput.dump({ "value" => Object.new })
    end
  end

  def test_yaml_rejects_cycles
    document = {}
    document["self"] = document
    assert_raises(Cvt::YAMLOutput::InvalidDocument) { Cvt::YAMLOutput.dump(document) }
  end

  def test_yaml_rejects_non_finite_floats
    assert_raises(Cvt::YAMLOutput::InvalidDocument) do
      Cvt::YAMLOutput.dump({ "value" => Float::NAN })
    end
  end

  def test_yaml_allows_shared_but_acyclic_values
    shared = { "code" => "x" }
    yaml = Cvt::YAMLOutput.dump({ "a" => shared, "b" => shared })
    assert_equal({ "a" => { "code" => "x" }, "b" => { "code" => "x" } }, YAML.safe_load(yaml))
  end

  def test_result_success
    route = Cvt::Route.new(backend: "vips", from: "png", to: "webp", priority: 10)
    result = Cvt::Result.success(
      operation: "convert",
      input: Cvt::YAMLOutput.input(path: "a.png", format: "png", bytes: 10),
      output: Cvt::YAMLOutput.output(path: "a.webp", format: "webp", bytes: 8),
      route: [route],
      timing: { "total_ms" => 5 }
    )

    assert result.ok?
    refute result.failure?
    assert_equal 0, result.exit_code
    assert_equal %w[ok version operation input output route options timing warnings],
                 result.to_h.keys
    assert_equal "vips", result.to_h["route"][0]["backend"]
    assert_equal "0.0.1-beta", YAML.safe_load(result.to_yaml)["version"]
  end

  def test_result_failure
    result = Cvt::Result.failure(
      operation: "convert",
      code: "output_exists",
      message: "Output file already exists",
      hint: "Pass --force to overwrite it."
    )

    refute result.ok?
    assert result.failure?
    assert_equal 6, result.exit_code
    assert_equal "output_exists", result.to_h["error"]["code"]
    assert_equal %w[ok version operation error warnings], result.to_h.keys
  end

  def test_result_failure_with_error_object
    result = Cvt::Result.failure(
      operation: "convert",
      error: Cvt::Errors.build("timeout", "Engine timed out", hint: "Raise --timeout")
    )
    assert_equal 8, result.exit_code
    assert_equal "Raise --timeout", result.to_h["error"]["hint"]
  end

  def test_format_contract
    format = Cvt::Format.new(id: "jpg", category: "image", extensions: ["jpg", "jpeg"],
                             mime: "image/jpeg", read: true, write: true, aliases: ["jpeg"])
    assert format.readable?
    assert format.writable?
    assert_equal "jpg", format.id
    assert_equal %w[jpg jpeg], format.extensions
    assert_equal %w[id category extensions mime aliases read write], format.to_h.keys
  end

  def test_route_contract
    route = Cvt::Route.new(backend: "native_archive", from: "xz", to: "bz2",
                           priority: 5, lossy: false, requirements: ["xz", "bzip2"])
    refute route.lossy?
    assert_equal %w[xz bzip2], route.requirements
    assert_equal %w[backend from to], route.to_h.keys
    assert_equal [5, "native_archive", "xz", "bz2"], route.sort_key
  end

  def test_backend_base_contract
    backend = Cvt::Backend.new
    refute backend.available?
    refute backend.available_for?("png", "webp", [])
    assert_nil backend.version
    assert_equal [], backend.requirements
    assert_raises(NotImplementedError) { backend.convert("a", "b", {}, []) }
  end

  def test_backend_class_dsl
    klass = Class.new(Cvt::Backend) do
      id "contract_probe"
      kind "native"
      priority 3
      requirements ["probe"]
      def available?
        true
      end
    end
    backend = klass.new
    assert_equal "contract_probe", backend.id
    assert_equal "native", backend.kind
    assert_equal 3, backend.priority
    assert_equal ["probe"], backend.requirements
    assert backend.available?
    assert backend.available_for?("png", "webp", [])
  end

  def test_backend_aggregator_reports_missing_adapters
    assert_nil Cvt::Backends.load("definitely_missing_backend")
    refute Cvt::Backends.available?("definitely_missing_backend")
    refute Cvt::Backends.available_for?("definitely_missing_backend", "png", "webp", [])
    assert_match(/unavailable/, Cvt::Backends.load_error("definitely_missing_backend"))
    assert_nil Cvt::Backends.load("../escape")
    assert_equal [], Cvt::Backends.available(["definitely_missing_backend"])
  ensure
    Cvt::Backends.reset!
  end
end
