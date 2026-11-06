# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "csv"
require "fileutils"
require "json"
require "minitest/autorun"
require "nokogiri"
require "tmpdir"
require "toml-rb"
require "yaml"

require "cvt"

class DataTest < Minitest::Test
  def setup
    @backend = Cvt::Backends.load("native_data")
    refute_nil @backend, "native_data backend must load"
    @dir = Dir.mktmpdir("cvt-data-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def convert(from, to, content, options = {})
    input = File.join(@dir, "input.#{from}")
    File.binwrite(input, content)
    convert_file(input, from, to, options)
  end

  def convert_file(input, from, to, options = {})
    output = File.join(@dir, "output.#{to}")
    warnings = []
    @backend.convert(input, output, { "from" => from, "to" => to }.merge(options), warnings)
    [File.binread(output), warnings]
  end

  def assert_conversion_error(from, to, content, options = {})
    error = assert_raises(Cvt::Error) { convert(from, to, content, options) }
    assert_equal "conversion_failed", error.code
    error
  end

  def assert_input_unreadable(from, to, content, options = {})
    error = assert_raises(Cvt::Error) { convert(from, to, content, options) }
    assert_equal "input_unreadable", error.code
    assert_equal 5, error.exit_code
    error
  end

  def test_availability_and_version
    assert @backend.available?
    formats = Cvt::Adapters::Data::FORMATS
    assert_equal %w[csv tsv json jsonl yaml xml toml], formats

    formats.each do |from|
      formats.each do |to|
        assert @backend.available_for?(from, to), "#{from} -> #{to} should be available"
      end
    end
    refute @backend.available_for?("csv", "xlsx")
    refute @backend.available_for?("xlsx", "json")
    assert_match(/nokogiri|toml-rb/, @backend.version.to_s)
  end

  def test_csv_to_json_keeps_strings_and_handles_quotes_and_crlf
    csv = "name,qty,note\r\nWidget,3,\"a,b\"\r\nGadget,2,\"line1\r\nline2\"\r\n"
    output, = convert("csv", "json", csv)
    rows = JSON.parse(output)

    assert_equal %w[name qty note], rows.first.keys
    assert_equal [{ "name" => "Widget", "qty" => "3", "note" => "a,b" },
                  { "name" => "Gadget", "qty" => "2", "note" => "line1\r\nline2" }], rows
    assert rows.flat_map(&:values).all? { |value| value.is_a?(String) }
    refute output.start_with?("\uFEFF")
    refute_includes output, "\r\n"
  end

  def test_csv_to_tsv_and_tab_delimiter
    tsv, = convert("csv", "tsv", "name,qty\nWidget,3\n")
    assert_equal "name\tqty\nWidget\t3\n", tsv

    rows, = convert("tsv", "json", tsv)
    assert_equal [{ "name" => "Widget", "qty" => "3" }], JSON.parse(rows)
  end

  def test_csv_delimiter_option
    output, = convert("csv", "json", "name|qty\nWidget|3\n", "delimiter" => "|")
    assert_equal [{ "name" => "Widget", "qty" => "3" }], JSON.parse(output)

    csv, = convert("json", "csv", "[{\"name\":\"Widget\",\"qty\":\"3\"}]", "delimiter" => "|")
    assert_equal "name|qty\nWidget|3\n", csv
  end

  def test_json_to_csv_uses_field_union_first_seen_and_stringifies_values
    json = JSON.generate([
                           { "name" => "a", "qty" => 3, "meta" => { "x" => 1 },
                             "tags" => %w[a b], "missing" => nil },
                           { "qty" => 4, "extra" => true }
                         ])
    csv, = convert("json", "csv", json)
    table = CSV.parse(csv, headers: true)
    assert_equal %w[name qty meta tags missing extra], table.headers
    assert_equal "a", table[0]["name"]
    assert_equal "3", table[0]["qty"]
    assert_equal '{"x":1}', table[0]["meta"]
    assert_equal '["a","b"]', table[0]["tags"]
    assert_equal "", table[0]["missing"]
    assert_equal "4", table[1]["qty"]
    assert_equal "true", table[1]["extra"]
  end

  def test_csv_missing_cells_become_empty_strings
    rows, = convert("csv", "json", "name,qty\nWidget\n")
    assert_equal [{ "name" => "Widget", "qty" => "" }], JSON.parse(rows)
  end

  def test_toml_writing_preserves_field_order_and_root
    csv = "qty,name,note\n3,Widget,hello\n"
    toml, = convert("csv", "toml", csv)

    assert_match(/\A\[\[rows\]\]/, toml)
    assert_operator toml.index('qty = "3"'), :<, toml.index('name = "Widget"')
    assert_operator toml.index('name = "Widget"'), :<, toml.index('note = "hello"')
    assert_equal [{ "qty" => "3", "name" => "Widget", "note" => "hello" }],
                 TomlRB.parse(toml)["rows"]

    rows, = convert("toml", "json", toml)
    assert_equal({ "rows" => [{ "qty" => "3", "name" => "Widget", "note" => "hello" }] },
                 JSON.parse(rows))

    custom, = convert("toml", "json", "[[items]]\nname = \"x\"\n", "root" => "items")
    assert_equal({ "items" => [{ "name" => "x" }] }, JSON.parse(custom))

    custom_out, = convert("csv", "toml", csv, "root" => "items")
    assert_match(/\A\[\[items\]\]/, custom_out)

    csv_back, = convert("toml", "csv", toml)
    assert_equal "qty,name,note\n3,Widget,hello\n", csv_back
  end

  def test_toml_date_literals_become_iso8601
    toml = "[[rows]]\nwhen = 2024-01-02\n"
    json, = convert("toml", "json", toml)
    assert_equal({ "rows" => [{ "when" => "2024-01-02" }] }, JSON.parse(json))

    csv, = convert("toml", "csv", toml)
    assert_equal "when\n2024-01-02\n", csv
  end

  def test_toml_object_to_json_and_yaml
    toml = "title = \"x\"\n[owner]\nname = \"y\"\n"
    expected = { "title" => "x", "owner" => { "name" => "y" } }

    json, = convert("toml", "json", toml)
    assert_equal expected, JSON.parse(json)

    yaml, = convert("toml", "yaml", toml)
    assert_equal expected, YAML.safe_load(yaml)
  end

  def test_json_object_to_toml
    json = JSON.generate({ "title" => "x", "owner" => { "name" => "y" }, "tags" => %w[a b] })
    toml, = convert("json", "toml", json)
    assert_equal({ "title" => "x", "owner" => { "name" => "y" }, "tags" => %w[a b] },
                 TomlRB.parse(toml))
  end

  def test_json_scalar_or_nontable_array_to_toml_fails
    %w["hello" [1,2]].each do |json|
      error = assert_conversion_error("json", "toml", json)
      assert_match(/top-level object/, error.message)
      assert_match(/JSON\/YAML object/, error.hint)
    end

    toml, = convert("json", "toml", JSON.generate([{ "name" => "x" }]))
    assert_match(/\A\[\[rows\]\]/, toml)
  end

  def test_toml_cannot_write_null_and_rejects_missing_root
    error = assert_conversion_error("json", "toml", JSON.generate([{ "name" => nil }]))
    assert_match(/null/, error.message)
    assert_match(/JSON or YAML/, error.hint)

    error = assert_conversion_error("toml", "csv", "name = \"x\"\n")
    assert_match(/root key/, error.message)
    assert_match("--root", error.hint)
  end

  def test_xml_round_trip_root_attributes_and_repeated_elements
    csv = "name,qty\nWidget,3\n"
    xml, = convert("csv", "xml", csv)
    document = Nokogiri::XML(xml)

    assert_equal "rows", document.root.name
    assert_equal %w[name qty], document.root.element_children.first.element_children.map(&:name)
    assert_equal({ "row" => { "name" => "Widget", "qty" => "3" } },
                 JSON.parse(convert("xml", "json", xml)[0]))
    assert_equal "name,qty\nWidget,3\n", convert("xml", "csv", xml)[0]

    source = '<items><row id="1"><name>A</name><name>B</name><desc>x</desc></row></items>'
    json, = convert("xml", "json", source, "root" => "items")
    assert_equal({ "row" => { "@id" => "1", "name" => %w[A B], "desc" => "x" } }, JSON.parse(json))

    namespaced = '<ns:items xmlns:ns="urn:x"><row><ns:name>v</ns:name></row></ns:items>'
    json, = convert("xml", "json", namespaced, "root" => "items")
    assert_equal({ "row" => { "ns:name" => "v" } }, JSON.parse(json))

    error = assert_conversion_error("xml", "csv", "<data><row><a>1</a></row></data>")
    assert_match(/root element/, error.message)
    assert_match("--root", error.hint)
  end

  def test_json_object_to_xml_and_back
    json = JSON.generate({ "name" => "x", "nested" => { "count" => 2 }, "tags" => %w[a b] })
    xml, = convert("json", "xml", json)
    document = Nokogiri::XML(xml)

    assert_equal "rows", document.root.name
    assert_equal %w[name nested tags tags], document.root.element_children.map(&:name)
    assert_equal %w[a b], document.root.element_children.select { |node| node.name == "tags" }.map(&:text)

    back, = convert("xml", "json", xml)
    assert_equal({ "name" => "x", "nested" => { "count" => "2" }, "tags" => %w[a b] },
                 JSON.parse(back))
  end

  def test_yaml_dates_and_single_document_rule
    yaml = "---\n- name: x\n  when: 2024-01-02\n"
    csv, = convert("yaml", "csv", yaml)
    assert_equal "name,when\nx,2024-01-02\n", csv

    json, = convert("yaml", "json", yaml)
    assert_equal [{ "name" => "x", "when" => "2024-01-02" }], JSON.parse(json)

    yaml_csv, = convert("csv", "yaml", "name,qty\nx,1\n")
    assert_equal [{ "name" => "x", "qty" => "1" }], YAML.safe_load(yaml_csv)

    single_key = "items:\n  - name: x\n"
    json, = convert("yaml", "json", single_key, "root" => "items")
    assert_equal({ "items" => [{ "name" => "x" }] }, JSON.parse(json))

    table_csv, = convert("yaml", "csv", single_key, "root" => "items")
    assert_equal "name\nx\n", table_csv

    error = assert_conversion_error("yaml", "json", "---\na: 1\n---\nb: 2\n")
    assert_match(/multiple documents/, error.message)
  end

  def test_json_object_scalar_and_array_pass_through_to_yaml
    json = JSON.generate({ "name" => "x", "nested" => { "count" => 2 }, "tags" => %w[a b] })
    expected = { "name" => "x", "nested" => { "count" => 2 }, "tags" => %w[a b] }

    yaml, = convert("json", "yaml", json)
    assert_equal expected, YAML.safe_load(yaml)

    back, = convert("yaml", "json", yaml)
    assert_equal expected, JSON.parse(back)

    assert_equal "hello", YAML.safe_load(convert("json", "yaml", '"hello"')[0])
    assert_equal [1, 2], YAML.safe_load(convert("json", "yaml", "[1,2]")[0])
  end

  def test_yaml_circular_reference_is_rejected
    yaml = "---\n- name: x\n  meta: &meta\n    self: *meta\n"
    error = assert_conversion_error("yaml", "json", yaml)
    assert_match(/circular reference/, error.message)
  end

  def test_jsonl_requires_objects_and_handles_streaming_layout
    jsonl = "{\"name\":\"a\",\"qty\":\"1\"}\n\n{\"name\":\"b\",\"qty\":\"2\"}\n"
    csv, = convert("jsonl", "csv", jsonl)
    assert_equal "name,qty\na,1\nb,2\n", csv

    output, = convert("csv", "jsonl", "name,qty\na,1\nb,2\n")
    lines = output.lines
    assert_equal 2, lines.size
    assert_equal [{ "name" => "a", "qty" => "1" }, { "name" => "b", "qty" => "2" }],
                 lines.map { |line| JSON.parse(line) }

    error = assert_conversion_error("jsonl", "csv", "[1,2]\n")
    assert_match(/must be an object/, error.message)
  end

  def test_encoding_option_and_invalid_bytes
    latin1 = "name\ncaf\xE9\n".b
    output, = convert("csv", "json", latin1, "encoding" => "ISO-8859-1")
    assert_equal [{ "name" => "caf\u00E9" }], JSON.parse(output)

    error = assert_input_unreadable("csv", "json", "name\n\xFF\n".b)
    assert_match(/not valid UTF-8/, error.message)
    assert_match("--encoding", error.hint)

    error = assert_input_unreadable("csv", "json", "name\nx\n", "encoding" => "NOT_AN_ENCODING")
    assert_match(/Unknown input encoding/, error.message)
    assert_match("--encoding", error.hint)

    error = assert_input_unreadable("csv", "json", "name\n\xFF\n".b, "encoding" => "ASCII-8BIT")
    assert_match(/cannot be decoded as ASCII-8BIT/, error.message)
    assert_match("--encoding", error.hint)

    declared = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" \
               "<rows><row><name>caf\u00E9</name></row></rows>"
    output, = convert("xml", "json", declared)
    assert_equal({ "row" => { "name" => "caf\u00E9" } }, JSON.parse(output))
  end

  def test_max_size_limit
    content = "name,qty\nWidget,3\n"
    error = assert_conversion_error("csv", "json", content, "max_size" => 10)
    assert_match(/exceeds the --max-size limit/, error.message)
    assert_match("--max-size", error.hint)

    output, = convert("csv", "json", content, "max_size" => 0)
    assert_equal [{ "name" => "Widget", "qty" => "3" }], JSON.parse(output)
  end

  def test_bad_table_shapes
    error = assert_conversion_error("json", "csv", "{\"name\":\"x\"}\n")
    assert_match(/array of objects/, error.message)
    assert_match(/top-level array of objects/, error.hint)

    error = assert_conversion_error("json", "csv", "[1,2]\n")
    assert_match(/record 1 must be an object/, error.message)

    error = assert_conversion_error("yaml", "csv", "name: x\n")
    assert_match(/array of objects/, error.message)

    error = assert_conversion_error("json", "csv", "{bad json\n")
    assert_match(/Invalid JSON/, error.message)
  end

  def test_output_is_utf8_lf_without_bom
    content = "\uFEFFname,qty\r\nWidget,3\r\n"
    json, = convert("json", "csv", JSON.generate([{ "name" => "Widget", "qty" => "3" }]))
    assert_equal "name,qty\nWidget,3\n", json
    refute json.start_with?("\uFEFF")

    output, = convert("csv", "json", content)
    refute output.start_with?("\uFEFF")
    assert_equal [{ "name" => "Widget", "qty" => "3" }], JSON.parse(output)
  end
end
