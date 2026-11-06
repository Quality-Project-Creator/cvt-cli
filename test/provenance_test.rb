# frozen_string_literal: true

require "minitest/autorun"
require "rubygems"

# Validates that ATTRIBUTION.md stays complete and does not claim to bundle
# copyleft engines. Spec R13 requires at least 12 direct references and 6
# subprocess engines, with an entry for every gemspec runtime dependency.
# libvips is recorded as shared-library because ruby-vips loads it through FFI.
class ProvenanceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ATTRIBUTION_PATH = File.join(ROOT, "ATTRIBUTION.md")
  GEMSPEC_PATH = File.join(ROOT, "cvt-cli.gemspec")

  REQUIRED_FIELDS = ["project", "upstream url", "license", "usage mode",
                     "local files", "notes"].freeze
  DIRECT_MODES = %w[runtime-gem adapted-code].freeze
  ENGINE_MODE = "subprocess-engine"
  SHARED_LIBRARY_MODE = "shared-library"
  ALLOWED_MODES = (DIRECT_MODES + [ENGINE_MODE, SHARED_LIBRARY_MODE]).freeze
  MIN_ENTRIES = 23

  # Specific claims that would mean GPL/AGPL/LGPL code is shipped or linked.
  FORBIDDEN_PATTERNS = [
    /\b(?:bundle|bundles|bundled|vendor|vendors|vendored|copy|copies|copied|link|links|linked|distribute|distributes|distributed|ship|ships|included)\b[^.\n]{0,60}\b(?:gpl|agpl|lgpl)\b/i,
    /\b(?:gpl|agpl|lgpl)\b[^.\n]{0,60}\b(?:bundled|vendored|copied|linked|distributed|included|shipped)\b/i
  ].freeze
  NEGATION = /\b(?:never|not|no|none|without|nor)\b/i

  class << self
    def attribution_text
      @attribution_text ||= File.read(ATTRIBUTION_PATH, encoding: "UTF-8")
    end

    def tables
      @tables ||= parse_tables(attribution_text)
    end

    private

    def parse_tables(markdown)
      tables = []
      header = nil
      rows = nil
      markdown.each_line(chomp: true) do |line|
        text = line.strip
        if text.start_with?("|")
          cells = text.sub(/\A\|/, "").sub(/\|\z/, "").split("|").map { |cell| normalize(cell) }
          if cells.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
            next
          elsif rows.nil?
            header = cells
            rows = []
          else
            rows << header.zip(cells).to_h
          end
        elsif rows
          tables << rows
          header = rows = nil
        end
      end
      tables << rows if rows

      tables.select { |table| table.first && REQUIRED_FIELDS.all? { |field| table.first.key?(field) } }
    end

    def normalize(cell)
      cell.to_s.gsub("`", "").strip.downcase.gsub(/\s+/, " ")
    end
  end

  def entries
    @entries ||= self.class.tables.flatten(1)
  end

  def direct_entries
    entries.select { |entry| DIRECT_MODES.include?(entry["usage mode"]) }
  end

  def engine_entries
    entries.select { |entry| entry["usage mode"] == ENGINE_MODE }
  end

  def shared_library_entries
    entries.select { |entry| entry["usage mode"] == SHARED_LIBRARY_MODE }
  end

  def entry_for(project)
    entries.find { |entry| entry["project"] == project }
  end

  def test_attribution_tables_are_present
    refute_empty entries, "ATTRIBUTION.md must contain attribution tables"
    refute_empty direct_entries, "ATTRIBUTION.md must list direct references"
    refute_empty engine_entries, "ATTRIBUTION.md must list subprocess engines"
  end

  def test_all_twenty_three_entries_are_present
    assert_operator entries.size, :>=, MIN_ENTRIES,
                    "expected at least #{MIN_ENTRIES} attribution entries " \
                    "(12 direct references plus 11 engines)"
    assert_equal entries.size, entries.map { |entry| entry["project"] }.uniq.size,
                 "attribution entries must be unique"
  end

  def test_at_least_twelve_direct_references
    assert_operator direct_entries.size, :>=, 12,
                    "expected at least 12 runtime-gem/adapted-code entries"
    assert_equal direct_entries.size, direct_entries.map { |entry| entry["project"] }.uniq.size,
                 "direct attribution entries must be unique"
  end

  def test_at_least_six_subprocess_engines
    assert_operator engine_entries.size, :>=, 6,
                    "expected at least 6 subprocess-engine entries"
    assert_equal engine_entries.size, engine_entries.map { |entry| entry["project"] }.uniq.size,
                 "engine attribution entries must be unique"
  end

  def test_libvips_is_classified_as_a_shared_library
    entry = entry_for("libvips/libvips")
    refute_nil entry, "ATTRIBUTION.md must have a libvips/libvips entry"
    assert_equal SHARED_LIBRARY_MODE, entry["usage mode"],
                 "libvips is loaded through FFI and must be recorded as shared-library"
    refute_includes engine_entries.map { |item| item["project"] }, "libvips/libvips",
                    "libvips must not be claimed as a subprocess engine"
    assert_match(/shared library/i, entry["notes"],
                 "libvips notes must mention the shared library")
    assert_match(/(?:not|never|does not)\b[^.]*bundle/i, entry["notes"],
                 "libvips notes must state that CVT does not bundle it")
    assert_match(/relinkable-shared-library/i, entry["notes"],
                 "libvips notes must document the LGPL relinkable-shared-library conditions")
    refute_empty shared_library_entries,
                 "ATTRIBUTION.md must list at least one shared-library entry"
  end

  def test_every_entry_has_required_fields
    entries.each do |entry|
      REQUIRED_FIELDS.each do |field|
        value = entry[field].to_s
        assert value.length.positive?,
               "#{entry["project"].inspect} is missing #{field.inspect}"
      end
      assert_includes ALLOWED_MODES, entry["usage mode"],
                      "#{entry["project"].inspect} has unknown usage mode #{entry["usage mode"].inspect}"
      assert entry["upstream url"].match?(%r{\Ahttps?://}),
             "#{entry["project"].inspect} has an invalid upstream URL"
    end
  end

  def test_every_gemspec_runtime_dependency_is_attributed
    direct_names = direct_entries.map do |entry|
      entry["project"].split("/").last.to_s.gsub(/[^a-z0-9]/, "")
    end
    refute_empty runtime_dependencies, "gemspec declares no runtime dependencies"
    runtime_dependencies.each do |name|
      key = name.downcase.gsub(/[^a-z0-9]/, "")
      assert_includes direct_names, key,
                      "runtime dependency #{name} has no direct attribution entry"
    end
  end

  def test_no_forbidden_bundling_claims
    offending = []
    self.class.attribution_text.each_line.with_index(1) do |line, number|
      next if NEGATION.match?(line)

      FORBIDDEN_PATTERNS.each do |pattern|
        offending << "#{number}: #{line.strip}" if pattern.match?(line)
      end
    end
    assert_empty offending,
                 "ATTRIBUTION.md must not claim to bundle or link copyleft code:\n#{offending.join("\n")}"
  end

  def test_compliance_statement_and_mit_license_notice
    text = self.class.attribution_text
    assert_match(/MIT License/, text, "ATTRIBUTION.md must name the MIT project license")
    assert_match(/no copyleft source code is copied/i, text,
                 "ATTRIBUTION.md must clearly state that no copyleft source is copied")
    assert_match(/never\s+(?:copied|bundled|vendored)/i, text,
                 "ATTRIBUTION.md must state that copyleft code is never copied, bundled, or vendored")
    assert_match(/shared library/i, text,
                 "ATTRIBUTION.md must document the libvips shared library")
    assert_match(/relinkable-shared-library/i, text,
                 "ATTRIBUTION.md must document the LGPL relinkable-shared-library conditions")
    assert_match(/separate processes/i, text,
                 "ATTRIBUTION.md must state that engines run as separate processes")
  end

  private

  def runtime_dependencies
    @runtime_dependencies ||= begin
      spec = Gem::Specification.load(GEMSPEC_PATH)
      raise "could not load #{GEMSPEC_PATH}" unless spec

      spec.runtime_dependencies.map(&:name)
    end
  end
end
