# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "marcel"
require "caxlsx"
require "csv"
require "date"
require "fileutils"
require "json"
require "minitest/autorun"
require "roo"
require "stringio"
require "tmpdir"
require "yaml"
require "zip"

require "cvt"

class SpreadsheetTest < Minitest::Test
  def setup
    @backend = Cvt::Backends.load("spreadsheet")
    refute_nil @backend, "spreadsheet backend must load"
    @dir = Dir.mktmpdir("cvt-sheet-")
    @book = build_book(File.join(@dir, "book.xlsx"))
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def build_book(path)
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "First") do |sheet|
      sheet.add_row ["name", "qty", "when"]
      sheet.add_row ["widget", 3, Date.new(2024, 1, 2)]
      sheet.add_row ["gadget", 2, Date.new(2024, 3, 4)]
    end
    package.workbook.add_worksheet(name: "Second") do |sheet|
      sheet.add_row ["code", "amount"]
      sheet.add_row ["x", 10]
      sheet.add_row ["y", 20]
    end
    package.serialize(path)
    path
  end

  def convert(input, from, to, options = {})
    output = File.join(@dir, "out.#{to}")
    warnings = []
    @backend.convert(input, output, { "from" => from, "to" => to }.merge(options), warnings)
    [output, warnings]
  end

  def assert_conversion_error(input, from, to, options = {})
    error = assert_raises(Cvt::Error) { convert(input, from, to, options) }
    assert_equal "conversion_failed", error.code
    error
  end

  def test_availability_and_version
    assert @backend.available?
    io = Cvt::Adapters::Data::SpreadsheetIO

    Cvt::Adapters::Data::FORMATS.each do |format|
      assert @backend.available_for?("xlsx", format), "xlsx -> #{format} should be available"
      assert @backend.available_for?(format, "xlsx"), "#{format} -> xlsx should be available"
    end
    if io.ods?
      Cvt::Adapters::Data::FORMATS.each do |format|
        assert @backend.available_for?("ods", format), "ods -> #{format} should be available"
      end
      assert @backend.available_for?("ods", "xlsx")
    end
    refute @backend.available_for?("xlsx", "ods")
    refute @backend.available_for?("csv", "json")
    assert_match(/roo|caxlsx/, @backend.version.to_s)
  end

  def test_marcel_loads_before_caxlsx_without_conflict
    marcel = Gem.loaded_specs["marcel"]
    refute_nil marcel
    assert_match(/\A1\./, marcel.version.to_s, "caxlsx requires marcel ~> 1.0")
    refute_nil Gem.loaded_specs["caxlsx"]
    assert defined?(Axlsx::Package)
  end

  def test_router_and_cli_prefer_spreadsheet_for_csv_to_xlsx
    source = File.join(@dir, "route.csv")
    File.write(source, "name,qty\nwidget,3\n")

    result = Cvt::Router.new(pool: Cvt::Backends).route("csv", "xlsx")
    assert result.ok?, "csv -> xlsx should have an available route"
    assert_equal %w[spreadsheet], result.steps.map(&:backend)

    target = File.join(@dir, "route.xlsx")
    out = StringIO.new
    code = Cvt::CLI.run([source, target], out: out)
    assert_equal 0, code
    document = YAML.safe_load(out.string)
    assert_equal true, document["ok"]
    assert_equal %w[spreadsheet], document["route"].map { |step| step["backend"] }
    assert File.exist?(target)
    assert_equal ["Sheet1"], Roo::Spreadsheet.open(target).sheets
  end

  def test_xlsx_to_csv_reads_first_sheet_and_reports_loss
    csv, warnings = convert(@book, "xlsx", "csv")
    table = CSV.parse(File.read(csv), headers: true)

    assert_equal %w[name qty when], table.headers
    assert_equal "widget", table[0]["name"]
    assert_equal "3", table[0]["qty"]
    assert_equal "2024-01-02", table[0]["when"]
    assert_equal %w[style_loss multi_sheet_ignored], warnings.map { |warning| warning["code"] }
  end

  def test_sheet_selection_by_name_and_index
    by_name, warnings = convert(@book, "xlsx", "csv", "sheet" => "Second")
    assert_equal "code,amount\nx,10\ny,20\n", File.read(by_name)
    assert_equal ["style_loss"], warnings.map { |warning| warning["code"] }

    by_index, = convert(@book, "xlsx", "csv", "sheet" => "2")
    assert_equal File.read(by_name), File.read(by_index)

    error = assert_conversion_error(@book, "xlsx", "csv", "sheet" => "Missing")
    assert_match(/Worksheet not found/, error.message)
    assert_match(/First, Second/, error.hint)

    error = assert_conversion_error(@book, "xlsx", "csv", "sheet" => "9")
    assert_match(/out of range/, error.message)
  end

  def test_xlsx_to_json_keeps_numbers_and_dates
    json, = convert(@book, "xlsx", "json")
    rows = JSON.parse(File.read(json))

    assert_equal [{ "name" => "widget", "qty" => 3, "when" => "2024-01-02" },
                  { "name" => "gadget", "qty" => 2, "when" => "2024-03-04" }], rows
  end

  def test_csv_to_xlsx_writes_sheet1_bold_header_and_widths
    source = File.join(@dir, "in.csv")
    File.write(source, "name,qty\nwidget,3\ngadget,2\n")
    xlsx, warnings = convert(source, "csv", "xlsx")
    assert_empty warnings

    reader = Roo::Spreadsheet.open(xlsx)
    assert_equal ["Sheet1"], reader.sheets
    assert_equal %w[name qty], reader.sheet(0).row(1)
    assert_equal ["widget", 3], reader.sheet(0).row(2)
    assert_equal 3, reader.sheet(0).last_row

    Zip::File.open(xlsx) do |zip|
      assert_match(/<b val="1"\/>/, zip.read("xl/styles.xml"))
      assert_match(/<cols>/, zip.read("xl/worksheets/sheet1.xml"))
      assert_nil zip.find_entry("xl/charts/chart1.xml")
      assert_nil zip.find_entry("xl/vbaProject.bin")
    end

    csv, = convert(xlsx, "xlsx", "csv")
    assert_equal "name,qty\nwidget,3\ngadget,2\n", File.read(csv)
  end

  def test_every_xlsx_to_data_route
    Cvt::Adapters::Data::FORMATS.each do |format|
      content, = convert(@book, "xlsx", format)
      text = File.binread(content)
      refute_empty text, "xlsx -> #{format} produced no output"
      rows = Cvt::Adapters::Data.parse(format, text)
      assert_equal "widget", rows[0]["name"]
    end
  end

  def test_every_data_to_xlsx_route
    rows = [{ "name" => "widget", "qty" => "3" }, { "name" => "gadget", "qty" => "2" }]
    Cvt::Adapters::Data::FORMATS.each do |format|
      source = File.join(@dir, "source.#{format}")
      Cvt::Adapters::Data.write(source, rows, { "to" => format })
      xlsx, = convert(source, format, "xlsx")

      reader = Roo::Spreadsheet.open(xlsx)
      assert_equal ["Sheet1"], reader.sheets
      assert_equal %w[name qty], reader.sheet(0).row(1)
      assert_equal "widget", reader.sheet(0).row(2)[0]
    end
  end

  def test_ods_read_routes_when_soffice_is_available
    skip "roo cannot read ODS" unless @backend.available_for?("ods", "csv")
    soffice = Cvt::Bin.find(%w[soffice libreoffice])
    skip "soffice is not installed" unless soffice

    result = Cvt::Shell.run([soffice, "--headless", "--convert-to", "ods",
                             "--outdir", @dir, @book], timeout: 120)
    ods = File.join(@dir, "book.ods")
    skip "soffice did not produce an ODS file" unless result.success? && File.exist?(ods)

    Cvt::Adapters::Data::FORMATS.each do |format|
      content, warnings = convert(ods, "ods", format)
      text = File.binread(content)
      refute_empty text, "ods -> #{format} produced no output"
      rows = Cvt::Adapters::Data.parse(format, text)
      assert_equal "widget", rows[0]["name"]
      assert_includes warnings.map { |warning| warning["code"] }, "style_loss"
    end

    xlsx, = convert(ods, "ods", "xlsx")
    reader = Roo::Spreadsheet.open(xlsx)
    assert_equal ["Sheet1"], reader.sheets
    assert_equal %w[name qty when], reader.sheet(0).row(1)
  end

  def test_missing_or_invalid_spreadsheet_fails_cleanly
    missing = File.join(@dir, "missing.xlsx")
    error = assert_conversion_error(missing, "xlsx", "csv")
    assert_match(/Unable to read spreadsheet/, error.message)
  end

  def test_encrypted_or_legacy_container_reports_input_protected
    locked = File.join(@dir, "locked.xlsx")
    File.binwrite(locked, "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b + "payload")
    error = assert_raises(Cvt::Error) { convert(locked, "xlsx", "csv") }
    assert_equal "input_protected", error.code
    assert_match(/password/, error.hint)
  end
end
