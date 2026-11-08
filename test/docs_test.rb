# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "cvt"
require "zip"

# Task 10 coverage: native_text offline conversions, plus Pandoc and
# LibreOffice integration tests that skip when the engine is absent. Calibre
# is optional and almost always skipped.
class DocsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("cvt-docs-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def fixture(name, content)
    path = File.join(@dir, name)
    File.binwrite(path, content)
    path
  end

  def read_utf8(path)
    File.binread(path).force_encoding(Encoding::UTF_8)
  end

  def require_engine(id)
    backend = Cvt::Backends.load(id)
    unless backend && backend.available?
      skip "#{id} is not installed (#{Cvt::Backends.load_error(id) || 'engine missing'})"
    end
    backend
  end

  def convert(backend, from, to, input, output, options = {})
    warnings = []
    options = { "from" => from, "to" => to, "timeout" => 180 }.merge(options)
    backend.convert(input, output, options, warnings)
    assert File.file?(output), "expected #{output} to exist"
    warnings
  end

  # ---------------------------------------------------------------- native_text

  def test_native_text_backend_is_available_offline
    backend = Cvt::Backends.load("native_text")
    refute_nil backend
    assert_equal "native_text", backend.id
    assert_equal "native", backend.kind
    assert backend.available?
  end

  def test_native_text_declares_only_its_routes
    backend = Cvt::Backends.load("native_text")
    [%w[md html], %w[md txt], %w[txt md], %w[txt html], %w[html txt]].each do |pair|
      assert backend.available_for?(*pair)
    end
    refute backend.available_for?("html", "md")
    refute backend.available_for?("pdf", "txt")
  end

  def test_markdown_to_html
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.md", "# Heading\n\nSome **bold** text.\n")
    output = File.join(@dir, "note.html")

    convert(backend, "md", "html", source, output)

    html = read_utf8(output)
    assert_includes html, "<h1"
    assert_includes html, "<strong>bold</strong>"
    assert_equal Encoding::UTF_8, html.encoding
    refute_includes html, "\r"
  end

  def test_markdown_fenced_code_block_becomes_pre
    backend = Cvt::Backends.load("native_text")
    source = fixture("code.md", "# Title\n\n```ruby\nputs \"hi\"\n```\n")
    output = File.join(@dir, "code.html")

    convert(backend, "md", "html", source, output)

    html = read_utf8(output)
    assert_includes html, "<pre>"
    assert_includes html, "puts \"hi\""
  end

  def test_markdown_to_text
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.md", "# Heading\n\nSome **bold** text.\n")
    output = File.join(@dir, "note.txt")

    convert(backend, "md", "txt", source, output)

    text = read_utf8(output)
    assert_includes text, "Heading"
    assert_includes text, "Some bold text."
    refute_includes text, "<"
    refute_includes text, "\r"
  end

  def test_text_to_markdown_copies_content
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.txt", "line one\nline two\n")
    output = File.join(@dir, "note.md")

    convert(backend, "txt", "md", source, output)

    assert_equal "line one\nline two\n", read_utf8(output)
  end

  def test_text_to_html_escapes_and_splits_paragraphs
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.txt", "a & b\n\n<script>alert(1)</script>\n")
    output = File.join(@dir, "note.html")

    convert(backend, "txt", "html", source, output)

    html = read_utf8(output)
    assert_includes html, "<p>a &amp; b</p>"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes html, "<script>"
    assert_equal 2, html.scan("<p>").size
  end

  def test_html_to_text
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.html", "<h1>Title</h1><p>Body &amp; more</p>\n")
    output = File.join(@dir, "note.txt")

    convert(backend, "html", "txt", source, output)

    text = read_utf8(output)
    assert_includes text, "Title"
    assert_includes text, "Body & more"
    refute_includes text, "<h1>"
  end

  def test_text_input_encoding_is_honoured
    backend = Cvt::Backends.load("native_text")
    source = fixture("latin1.txt", "caf\xE9\n".b)
    output = File.join(@dir, "latin1.html")

    convert(backend, "txt", "html", source, output, "encoding" => "ISO-8859-1")

    assert_includes read_utf8(output), "café"
  end

  def test_invalid_encoding_reports_input_unreadable
    backend = Cvt::Backends.load("native_text")
    source = fixture("broken.txt", "\xFF\xFE\n".b)
    output = File.join(@dir, "broken.html")

    error = assert_raises(Cvt::Error) do
      convert(backend, "txt", "html", source, output)
    end
    assert_equal "input_unreadable", error.code
    assert_equal 5, error.exit_code
    refute File.exist?(output)
  end

  def test_unsupported_text_pair_is_rejected
    backend = Cvt::Backends.load("native_text")
    source = fixture("note.html", "<p>text</p>\n")
    output = File.join(@dir, "note.md")

    error = assert_raises(Cvt::Error) do
      convert(backend, "html", "md", source, output)
    end
    assert_equal "unsupported_conversion", error.code
  end

  # ---------------------------------------------------------------------- pandoc

  def pandoc
    require_engine("pandoc")
  end

  def test_pandoc_capabilities
    backend = pandoc
    assert_equal "cli", backend.kind
    refute_nil backend.version

    assert backend.available_for?("md", "html")
    assert backend.available_for?("md", "docx")
    assert backend.available_for?("html", "md")
    assert backend.available_for?("epub", "docx")

    refute backend.available_for?("md", "pdf"), "pandoc must never be used for PDF"
    refute backend.available_for?("md", "md"), "same-format conversion must be skipped"
    refute backend.available_for?("md", "txt")
  end

  def test_pandoc_markdown_to_html
    backend = pandoc
    source = fixture("pandoc-note.md", "# Title\n\nSome **bold** text.\n")
    output = File.join(@dir, "pandoc-note.html")

    convert(backend, "md", "html", source, output)

    html = read_utf8(output)
    assert_includes html, "<h1"
    assert_includes html, "<strong>bold</strong>"
  end

  def test_pandoc_markdown_to_docx
    backend = pandoc
    source = fixture("pandoc-note.md", "# Title\n\nSome **bold** text.\n")
    output = File.join(@dir, "pandoc-note.docx")

    convert(backend, "md", "docx", source, output)

    assert_equal "PK", read_utf8(output)[0, 2]
    assert zip_entry(output, "word/document.xml"), "DOCX must contain word/document.xml"
  end

  def test_pandoc_html_to_markdown
    backend = pandoc
    source = fixture("pandoc-note.html", "<h1>Title</h1><p>Some <strong>bold</strong> text.</p>\n")
    output = File.join(@dir, "pandoc-back.md")

    convert(backend, "html", "md", source, output)

    text = read_utf8(output)
    assert_includes text, "# Title"
    assert_includes text, "**bold**"
  end

  def test_pandoc_epub_to_docx
    backend = pandoc
    source = fixture("book.md", "# Chapter\n\nSome text.\n")
    epub = File.join(@dir, "book.epub")
    docx = File.join(@dir, "book.docx")

    convert(backend, "md", "epub", source, epub)
    convert(backend, "epub", "docx", epub, docx)

    assert zip_entry(docx, "word/document.xml")
  end

  def test_pandoc_refuses_pdf_output
    backend = pandoc
    source = fixture("no-pdf.md", "# Title\n")
    output = File.join(@dir, "no-pdf.pdf")

    error = assert_raises(Cvt::Error) do
      convert(backend, "md", "pdf", source, output)
    end
    assert_equal "unsupported_conversion", error.code
    refute File.exist?(output)
  end

  def test_pandoc_engine_failure_reports_truncated_stderr
    backend = pandoc
    source = fixture("broken.docx", "this is not a zip")
    output = File.join(@dir, "broken.html")

    error = assert_raises(Cvt::Error) do
      convert(backend, "docx", "html", source, output)
    end
    assert_equal "conversion_failed", error.code
    assert_equal 7, error.exit_code
    assert error.details && error.details["stderr"]
    refute File.exist?(output)
  end

  # ----------------------------------------------------------------- libreoffice

  def libreoffice
    require_engine("libreoffice")
  end

  def make_docx(name)
    docx = File.join(@dir, "#{name}.docx")
    backend = Cvt::Backends.load("pandoc")
    if backend&.available?
      markdown = fixture("#{name}.md", "# Hello CVT\n\nDocument body.\n")
      convert(backend, "md", "docx", markdown, docx)
    else
      html = fixture("#{name}.html", "<h1>Hello CVT</h1><p>Document body.</p>\n")
      convert(libreoffice, "html", "docx", html, docx)
    end
    docx
  end

  def make_xlsx
    csv = fixture("rows.csv", "name,value\nalpha,1\nbeta,2\n")
    xlsx = File.join(@dir, "rows.xlsx")
    convert(libreoffice, "csv", "xlsx", csv, xlsx)
    xlsx
  end

  def test_libreoffice_capabilities
    backend = libreoffice
    assert_equal "cli", backend.kind
    refute_nil backend.version

    assert backend.available_for?("docx", "pdf")
    assert backend.available_for?("html", "pdf")
    assert backend.available_for?("txt", "docx")
    assert backend.available_for?("xlsx", "ods")
    assert backend.available_for?("csv", "xlsx")
    assert backend.available_for?("xlsx", "pdf")

    refute backend.available_for?("docx", "xlsx"), "writer to spreadsheet is unsupported"
    refute backend.available_for?("pdf", "docx")
  end

  def test_libreoffice_csv_to_xlsx
    backend = libreoffice
    csv = fixture("rows.csv", "name,value\nalpha,1\nbeta,2\n")
    xlsx = File.join(@dir, "rows.xlsx")

    convert(backend, "csv", "xlsx", csv, xlsx)

    assert_equal "PK", read_utf8(xlsx)[0, 2]
    assert zip_entry(xlsx, "xl/workbook.xml"), "XLSX must contain xl/workbook.xml"
  end

  def test_libreoffice_xlsx_to_ods
    backend = libreoffice
    xlsx = make_xlsx
    ods = File.join(@dir, "rows.ods")

    convert(backend, "xlsx", "ods", xlsx, ods)

    assert_equal "PK", read_utf8(ods)[0, 2]
    assert_equal "application/vnd.oasis.opendocument.spreadsheet",
                 zip_entry(ods, "mimetype")
  end

  def test_libreoffice_xlsx_to_pdf
    backend = libreoffice
    xlsx = make_xlsx
    pdf = File.join(@dir, "rows.pdf")

    convert(backend, "xlsx", "pdf", xlsx, pdf)

    assert_equal "%PDF", read_utf8(pdf)[0, 4]
  end

  def test_libreoffice_docx_to_pdf
    backend = libreoffice
    docx = make_docx("report")
    pdf = File.join(@dir, "report.pdf")

    convert(backend, "docx", "pdf", docx, pdf)

    assert_equal "%PDF", read_utf8(pdf)[0, 4]
  end

  def test_markdown_to_pdf_uses_html_step_then_libreoffice
    html = File.join(@dir, "notes.html")
    md = fixture("notes.md", "# Notes\n\nA paragraph with **bold** text.\n")
    native = Cvt::Backends.load("native_text")

    convert(native, "md", "html", md, html)
    libreoffice.convert(
      html,
      File.join(@dir, "notes.pdf"),
      { "from" => "html", "to" => "pdf", "timeout" => 180 },
      []
    )

    pdf = File.join(@dir, "notes.pdf")
    assert_equal "%PDF", read_utf8(pdf)[0, 4]
  end

  def test_libreoffice_docx_to_txt_warns_about_style_loss
    backend = libreoffice
    docx = make_docx("report")
    output = File.join(@dir, "report.txt")

    warnings = convert(backend, "docx", "txt", docx, output)

    text = read_utf8(output)
    assert_includes text, "Hello CVT"
    assert_includes warnings.map { |warning| warning["code"] }, "style_loss"
  end

  def test_libreoffice_rejects_unsupported_pair
    backend = libreoffice
    docx = make_docx("report")
    output = File.join(@dir, "report.xlsx")

    error = assert_raises(Cvt::Error) do
      convert(backend, "docx", "xlsx", docx, output)
    end
    assert_equal "unsupported_conversion", error.code
    refute File.exist?(output)
  end

  # --------------------------------------------------------------------- calibre

  def test_calibre_backend_reports_honest_availability
    backend = Cvt::Backends.load("calibre")
    refute_nil backend
    assert_equal "calibre", backend.id
    assert_equal "cli", backend.kind
    assert_equal !backend.binary.nil?, backend.available?
  end

  def test_calibre_epub_to_mobi
    backend = require_engine("calibre")
    pandoc = Cvt::Backends.load("pandoc")
    skip "pandoc is required to build an EPUB fixture" unless pandoc&.available?

    markdown = fixture("book.md", "# Chapter\n\nSome text.\n")
    epub = File.join(@dir, "book.epub")
    convert(pandoc, "md", "epub", markdown, epub)

    mobi = File.join(@dir, "book.mobi")
    convert(backend, "epub", "mobi", epub, mobi)

    assert_operator File.size(mobi), :>, 0
  end

  def test_calibre_epub_to_pdf
    backend = require_engine("calibre")
    pandoc = Cvt::Backends.load("pandoc")
    skip "pandoc is required to build an EPUB fixture" unless pandoc&.available?

    markdown = fixture("book.md", "# Chapter\n\nSome text.\n")
    epub = File.join(@dir, "book.epub")
    convert(pandoc, "md", "epub", markdown, epub)

    pdf = File.join(@dir, "book.pdf")
    convert(backend, "epub", "pdf", epub, pdf)

    assert_equal "%PDF", read_utf8(pdf)[0, 4]
  end

  def test_calibre_missing_engine_reports_backend_unavailable
    backend = Cvt::Backends.load("calibre")
    skip "calibre is installed; the unavailable path cannot be exercised" if backend.available?

    epub = fixture("fake.epub", "not an ebook")
    error = assert_raises(Cvt::Error) do
      convert(backend, "epub", "mobi", epub, File.join(@dir, "fake.mobi"))
    end
    assert_equal "backend_unavailable", error.code
    assert_equal 4, error.exit_code
  end

  private

  def zip_entry(path, entry)
    Zip::File.open(path) { |zip| zip.read(entry) }
  rescue StandardError
    nil
  end
end
