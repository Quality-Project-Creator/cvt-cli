# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "set"
require "cvt"

class RegistryTest < Minitest::Test
  CATEGORY_COUNTS = {
    "image" => 12,
    "audio" => 8,
    "video" => 6,
    "document" => 12,
    "data" => 9,
    "archive" => 6,
    "subtitle" => 3
  }.freeze

  EXPECTED_FORMATS = {
    "image" => %w[png jpg webp gif bmp tiff ico svg avif heic pnm tga],
    "audio" => %w[mp3 wav flac ogg opus aac m4a aiff],
    "video" => %w[mp4 mkv webm mov avi m4v],
    "document" => %w[txt md html pdf docx odt rtf epub mobi azw3 rst tex],
    "data" => %w[csv tsv json jsonl yaml xml toml xlsx ods],
    "archive" => %w[zip tar tgz gz xz bz2],
    "subtitle" => %w[srt vtt ass]
  }.freeze

  EXPECTED_BACKENDS = %w[
    native_data native_text native_archive native_subtitle spreadsheet vips
    imagemagick rsvg pdf ffmpeg pandoc libreoffice calibre
  ].freeze

  EXPECTED_FORMAT_COUNT = 56

  EXPECTED_ALIASES = {
    "jpeg" => "jpg", "jpe" => "jpg", "jfif" => "jpg",
    "tif" => "tiff",
    "markdown" => "md", "mdown" => "md", "mkd" => "md",
    "htm" => "html", "xhtml" => "html",
    "text" => "txt",
    "yml" => "yaml",
    "ndjson" => "jsonl", "jsonlines" => "jsonl",
    "ppm" => "pnm", "pgm" => "pnm", "pbm" => "pnm",
    "tar.gz" => "tgz", ".tar.gz" => "tgz",
    "ssa" => "ass",
    "subrip" => "srt",
    "webvtt" => "vtt"
  }.freeze

  def setup
    @registry = Cvt::Registry.default
  end

  def test_format_count_and_categories
    assert_equal 56, @registry.formats.size
    assert_equal EXPECTED_FORMAT_COUNT, EXPECTED_FORMATS.values.sum(&:size)

    assert_equal EXPECTED_FORMATS.keys, Cvt::Format::CATEGORIES
    EXPECTED_FORMATS.each do |category, ids|
      assert_equal ids.sort, @registry.category(category).map(&:id).sort
      assert_equal CATEGORY_COUNTS[category], @registry.category(category).size
    end
    assert_nil @registry.category("unknown")
  end

  def test_every_canonical_format_is_declared_exactly_once
    expected = EXPECTED_FORMATS.values.flatten.sort
    assert_equal expected, @registry.formats.map(&:id).sort

    ids = @registry.formats.map(&:id)
    assert_equal ids.uniq, ids
  end

  def test_formats_are_sorted_by_category_then_id
    sorted = @registry.formats.sort_by do |format|
      [Cvt::Format::CATEGORIES.index(format.category), format.id]
    end
    assert_equal sorted.map(&:id), @registry.formats.map(&:id)
  end

  def test_unique_aliases_and_aliases_do_not_shadow_canonical_ids
    aliases = @registry.formats.flat_map do |format|
      format.aliases.map { |name| normalize(name) }
    end
    assert_equal aliases.uniq, aliases

    canonical_ids = @registry.formats.map(&:id)
    assert_empty(aliases & canonical_ids)
  end

  def test_alias_lookup
    EXPECTED_ALIASES.each do |name, canonical|
      format = @registry.format(name)
      refute_nil format, "alias #{name} did not resolve"
      assert_equal canonical, format.id
    end

    @registry.formats.each do |format|
      format.aliases.each do |name|
        assert_equal format.id, @registry.format(name).id
      end
    end
  end

  def test_case_insensitive_lookup
    assert_equal "jpg", @registry.format("JPEG").id
    assert_equal "png", @registry.format_for_extension(".PNG").id
    assert_equal "tgz", @registry.format(".TAR.GZ").id
    assert_nil @registry.format("not_a_format")
    assert_nil @registry.format_for_extension("nope")
  end

  def test_extensions_are_unique_and_resolve_to_their_format
    extensions = @registry.formats.flat_map(&:extensions)
    assert_equal extensions.uniq, extensions

    @registry.formats.each do |format|
      format.extensions.each do |extension|
        assert_equal format.id, @registry.format_for_extension(extension).id
      end
    end
  end

  def test_compound_extension_resolution
    assert_equal "tgz", @registry.format_for_filename("bundle.tar.gz").id
    assert_equal "tgz", @registry.format_for_filename("/tmp/BUNDLE.TAR.GZ").id
    assert_equal "gz", @registry.format_for_extension(".gz").id
    assert_equal "jpg", @registry.format_for_filename("photo.JPEG").id
    assert_equal "tar", @registry.format_for_filename("bundle.tar").id
    assert_nil @registry.format_for_filename("README")
  end

  def test_svg_is_read_only
    svg = @registry.format("svg")
    assert svg.readable?
    refute svg.writable?
    refute_empty @registry.routes_from("svg")
  end

  def test_mime_lookup
    assert_equal "jpg", @registry.format_for_mime("image/jpeg").id
    assert_equal "jpg", @registry.format_for_mime("image/jpeg; charset=binary").id
    assert_nil @registry.format_for_mime("application/unknown")
  end

  def test_backend_declarations
    assert_equal 13, @registry.backends.size
    assert_equal EXPECTED_BACKENDS.sort, @registry.backend_ids.sort
    EXPECTED_BACKENDS.each do |id|
      info = @registry.backend(id)
      refute_nil info
      assert_equal id, info.id
      refute_empty info.kind
    end
    assert_nil @registry.backend("not_a_backend")
  end

  def test_routes_reference_known_endpoints_and_backends
    format_ids = @registry.formats.map(&:id)
    backend_ids = @registry.backend_ids

    @registry.routes.each do |route|
      assert_includes backend_ids, route.backend
      assert_includes format_ids, route.from
      assert_includes format_ids, route.to
      refute_equal route.from, route.to
      assert_kind_of Integer, route.priority
      assert_includes [true, false], route.lossy?
      assert_kind_of Array, route.requirements
      assert route.requirements.all? { |name| name.is_a?(String) }
    end
  end

  def test_every_readable_and_writable_format_has_a_route
    @registry.readable_formats.each do |format|
      refute_empty @registry.routes_from(format.id), "#{format.id} has no outgoing route"
    end
    @registry.writable_formats.each do |format|
      refute_empty @registry.routes_to(format.id), "#{format.id} has no incoming route"
    end
  end

  def test_direct_key_routes
    assert_equal "pdf", direct_backend("png", "pdf")
    assert_equal "rsvg", direct_backend("svg", "pdf")
    assert_equal "native_text", direct_backend("md", "html")
    assert_equal "libreoffice", direct_backend("html", "pdf")
    assert_equal "libreoffice", direct_backend("docx", "pdf")
    assert_equal "libreoffice", direct_backend("xlsx", "pdf")
    assert_equal "spreadsheet", direct_backend("csv", "xlsx")
    assert_equal "pdf", direct_backend("pdf", "png")
  end

  def test_two_hop_key_routes_are_declared
    assert_edge("md", "html", "native_text")
    assert_edge("html", "pdf", "libreoffice")

    assert_edge("docx", "pdf", "libreoffice")
    assert_edge("pdf", "png", "pdf")

    assert_edge("csv", "xlsx", "spreadsheet")
    assert_edge("xlsx", "pdf", "libreoffice")
  end

  def test_forbidden_direct_routes
    assert_empty @registry.direct_routes("pdf", "docx")
    assert_empty @registry.direct_routes("pdf", "md")
    assert_empty @registry.direct_routes("md", "pdf")
    assert_empty @registry.direct_routes("csv", "pdf")
  end

  def test_backend_priority_prefers_expected_direct_route
    png_webp = @registry.direct_routes("png", "webp")
    assert_equal "vips", png_webp.first.backend
    assert_equal "imagemagick", png_webp.last.backend

    csv_xlsx = @registry.direct_routes("csv", "xlsx")
    assert_equal "spreadsheet", csv_xlsx.first.backend

    pdf_png = @registry.direct_routes("pdf", "png")
    assert_equal "pdf", pdf_png.first.backend
    assert_equal "vips", pdf_png.last.backend
  end

  def test_groups_are_expanded
    assert_equal 7, @registry.group("data_text").size
    assert_nil @registry.group("missing_group")
    assert_edge("zip", "tgz", "native_archive")
    assert_edge("tar", "zip", "native_archive")
    assert_edge("gz", "xz", "native_archive")

    xz_to_bz2 = @registry.direct_routes("xz", "bz2").first
    assert_includes xz_to_bz2.requirements, "xz"
    assert_includes xz_to_bz2.requirements, "bzip2"
  end

  def test_route_order_is_deterministic
    first = Cvt::Registry.load
    second = Cvt::Registry.load
    assert_equal first.routes.map(&:sort_key), second.routes.map(&:sort_key)
    assert_equal first.formats.map(&:id), second.formats.map(&:id)
  end

  def test_availability_filtering_without_adapters
    pool = Class.new do
      def initialize(allowed)
        @allowed = allowed
      end

      def available_for?(backend, _from, _to, _requirements)
        @allowed.include?(backend)
      end
    end.new(%w[native_data native_text])

    routes = @registry.available_routes(pool: pool)
    refute_empty routes
    assert routes.all? { |route| %w[native_data native_text].include?(route.backend) }

    assert_empty @registry.available_routes(from: "zzz", pool: pool)
    assert_empty @registry.available_routes(to: "zzz", pool: pool)
  end

  def test_availability_errors_degrade_to_unavailable
    pool = Class.new do
      def available_for?(_backend, _from, _to, _requirements)
        raise "probe failed"
      end
    end.new

    assert_empty @registry.available_routes(pool: pool)
    refute @registry.route_available?(@registry.routes.first, pool: pool)
  end

  private

  def normalize(name)
    name.to_s.downcase.delete_prefix(".")
  end

  def direct_backend(from, to)
    @registry.direct_routes(from, to).first.backend
  end

  def assert_edge(from, to, backend)
    route = @registry.direct_routes(from, to).find { |candidate| candidate.backend == backend }
    refute_nil route, "missing edge #{backend}: #{from} -> #{to}"
  end
end
