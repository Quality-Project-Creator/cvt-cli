# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "cvt"

class RouterTest < Minitest::Test
  ALL_BACKENDS = %w[
    native_data native_text native_archive native_subtitle spreadsheet vips
    imagemagick rsvg pdf ffmpeg pandoc libreoffice calibre
  ].freeze

  class FakePool
    def initialize(allowed, tools: %w[xz bzip2 7z])
      @allowed = Array(allowed).map(&:to_s)
      @tools = Array(tools).map(&:to_s)
    end

    def available_for?(backend, _from, _to, requirements = [])
      @allowed.include?(backend.to_s) &&
        Array(requirements).all? { |tool| @tools.include?(tool.to_s) }
    end
  end

  class RaisingPool
    def available_for?(*)
      raise "probe failed"
    end
  end

  def setup
    @registry = Cvt::Registry.default
  end

  def router(allowed, tools: %w[xz bzip2 7z])
    Cvt::Router.new(registry: @registry, pool: FakePool.new(allowed, tools: tools))
  end

  def test_direct_route_prefers_lower_priority_backend
    result = router(ALL_BACKENDS).route("png", "webp")
    assert result.ok?
    assert_equal 1, result.steps.size
    assert_equal "vips", result.steps.first.backend
    refute_includes result.warnings.map { |warning| warning["code"] }, "multi_step_route"
  end

  def test_direct_route_falls_back_when_preferred_backend_is_unavailable
    result = router(%w[imagemagick]).route("png", "webp")
    assert result.ok?
    assert_equal "imagemagick", result.steps.first.backend
  end

  def test_key_two_hop_routes
    {
      %w[md pdf] => %w[native_text libreoffice],
      %w[docx png] => %w[libreoffice pdf],
      %w[csv pdf] => %w[spreadsheet libreoffice]
    }.each do |(from, to), backends|
      result = router(ALL_BACKENDS).route(from, to)
      assert result.ok?, "expected a route for #{from}->#{to}"
      assert_equal 2, result.steps.size
      assert_equal backends, result.steps.map(&:backend)
      assert_equal "multi_step_route", result.warnings.first["code"]
    end
  end

  def test_direct_png_pdf_and_svg_pdf_routes
    assert_equal %w[pdf], router(ALL_BACKENDS).route("png", "pdf").steps.map(&:backend)
    assert_equal %w[rsvg], router(ALL_BACKENDS).route("svg", "pdf").steps.map(&:backend)
  end

  def test_pdf_to_docx_and_md_are_unsupported
    %w[docx md].each do |to|
      result = router(ALL_BACKENDS).route("pdf", to)
      refute result.ok?
      assert_equal "unsupported_conversion", result.error.code
      assert_equal 3, result.error.exit_code
      assert_includes result.error.hint, "txt"
    end
  end

  def test_txt_is_never_used_as_an_intermediate
    result = router(ALL_BACKENDS).route("md", "pdf")
    assert result.ok?
    refute_includes result.steps.map(&:to), "txt"
    refute_includes result.steps.map(&:from), "txt"
    assert_equal %w[native_text libreoffice], result.steps.map(&:backend)
  end

  def test_two_hop_routes_have_at_most_two_steps
    %w[png pdf docx csv].each do |from|
      %w[pdf png json txt].each do |to|
        result = router(ALL_BACKENDS).route(from, to)
        next unless result.ok?

        assert_operator result.steps.size, :<=, 2
        assert_operator result.steps.size, :>=, 1
      end
    end
  end

  def test_unavailable_route_reports_backend_unavailable
    result = router([]).route("md", "pdf")
    refute result.ok?
    assert_equal "backend_unavailable", result.error.code
    assert_equal 4, result.error.exit_code
    assert_includes result.error.hint, "--doctor"
    assert_includes result.error.hint, "Missing backend"
    assert_includes result.error.message, "No available backend"
  end

  def test_no_route_reports_unsupported_conversion
    result = router(ALL_BACKENDS).route("png", "docx")
    refute result.ok?
    assert_equal "unsupported_conversion", result.error.code
    assert_equal 3, result.error.exit_code
  end

  def test_backend_restriction_applies_to_every_step
    result = router(ALL_BACKENDS).route("png", "webp", backend: "imagemagick")
    assert result.ok?
    assert_equal ["imagemagick"], result.steps.map(&:backend)

    result = router(ALL_BACKENDS).route("md", "pdf", backend: "native_text")
    refute result.ok?
    assert_equal "backend_unavailable", result.error.code
    assert_includes result.error.hint, "--backend"
  end

  def test_backend_restriction_selects_matching_two_hop_chain
    result = router(%w[libreoffice]).route("docx", "txt", backend: "libreoffice")
    assert result.ok?
    assert_equal ["libreoffice"], result.steps.map(&:backend)
  end

  def test_route_requirements_are_passed_to_the_pool
    result = router(%w[native_archive], tools: %w[bzip2]).route("gz", "xz")
    refute result.ok?
    assert_equal "backend_unavailable", result.error.code
    assert_includes result.error.hint, "native_archive"

    result = router(%w[native_archive], tools: %w[xz bzip2]).route("gz", "xz")
    assert result.ok?
    assert_equal %w[native_archive], result.steps.map(&:backend)
  end

  def test_routes_are_deterministic
    first = router(ALL_BACKENDS).route("docx", "png")
    steps = 10.times.map do
      router(ALL_BACKENDS).route("docx", "png").steps.map { |step| [step.backend, step.from, step.to] }
    end
    assert_equal steps.first, steps.last
    assert_equal first.steps.map { |step| [step.backend, step.from, step.to] }, steps.first
  end

  def test_lossy_routes_add_a_warning
    result = router(ALL_BACKENDS).route("png", "jpg")
    assert result.ok?
    assert_equal "lossy_conversion", result.warnings.first["code"]
  end

  def test_unknown_formats_are_reported
    result = router(ALL_BACKENDS).route("nope", "webp")
    refute result.ok?
    assert_equal "unknown_format", result.error.code
    assert_equal 2, result.error.exit_code

    result = router(ALL_BACKENDS).route("png", "nope")
    refute result.ok?
    assert_equal "unknown_format", result.error.code
  end

  def test_pool_errors_degrade_to_unavailable
    result = Cvt::Router.new(registry: @registry, pool: RaisingPool.new).route("png", "webp")
    refute result.ok?
    assert_equal "backend_unavailable", result.error.code
  end

  def test_same_format_is_unsupported
    result = router(ALL_BACKENDS).route("png", "png")
    refute result.ok?
    assert_equal "unsupported_conversion", result.error.code
  end
end
