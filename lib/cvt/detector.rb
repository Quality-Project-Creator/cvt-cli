# frozen_string_literal: true

require "csv"
require "date"
require "json"
require "psych"
require "zlib"

module Cvt
  # Detects the canonical format of an input file.
  #
  # Precedence (spec R4): explicit --from, binary MIME magic, extension, then
  # text sniffing. Generic `text/plain` and `application/octet-stream` magic
  # fall through so the extension and sniffers still get a chance. The detector
  # never raises for unreadable or unknown files: it returns a Result whose
  # `format` may be nil.
  class Detector
    Result = Struct.new(:format, :warnings, keyword_init: true) do
      def id
        format&.id
      end
    end

    GENERIC_MIMES = ["text/plain", "application/octet-stream", "application/x-empty"].freeze
    # Formats whose MIME magic is textual. A textual extension wins over a
    # textual magic result; binary magic always wins and produces a warning.
    TEXTUAL_FORMATS = %w[
      txt md html xml csv tsv json jsonl yaml toml srt vtt ass svg rst tex
    ].freeze
    ZIP_MAGICS = ["PK\x03\x04".b, "PK\x05\x06".b, "PK\x07\x08".b].freeze
    SNIFF_BYTES = 128 * 1024
    RAW_SEARCH_BYTES = 64 * 1024
    MIN_TEXT_CONFIDENCE = 0.5

    ODF_MIMES = {
      "application/vnd.oasis.opendocument.text" => "odt",
      "application/vnd.oasis.opendocument.spreadsheet" => "ods"
    }.freeze

    def initialize(registry: Cvt::Registry.default)
      @registry = registry
    end

    # `from` overrides detection entirely, matching the CLI contract. An
    # unknown override yields a Result with a nil format; the CLI reports
    # unknown_format before calling here.
    def detect(path, from: nil)
      warnings = []
      unless from.nil? || from.to_s.empty?
        return Result.new(format: @registry.format(from), warnings: warnings)
      end

      path = path.to_s
      return Result.new(format: nil, warnings: warnings) unless readable_file?(path)

      head = read_head(path, 1024)
      magic = magic_format(path, head) || mime_format(path)
      extension = @registry.format_for_filename(path)

      # Marcel reports an extensionless SVG as application/xml; the text
      # sniffer knows the more specific SVG/HTML shapes.
      if magic && magic.id == "xml"
        sniffed = sniff_format(path)
        magic = sniffed if sniffed && %w[svg html].include?(sniffed.id)
      end

      if magic
        return Result.new(format: choose_magic(magic, extension, warnings), warnings: warnings)
      end

      return Result.new(format: extension, warnings: warnings) if extension

      Result.new(format: sniff_format(path), warnings: warnings)
    rescue StandardError
      Result.new(format: nil, warnings: warnings)
    end

    private

    def readable_file?(path)
      File.file?(path) && File.readable?(path)
    rescue StandardError
      false
    end

    def read_head(path, length)
      File.binread(path, length) || "".b
    rescue StandardError
      "".b
    end

    def choose_magic(magic, extension, warnings)
      return magic unless extension
      return magic if extension.id == magic.id
      # Spec R4: .tar.gz/.tgz extensions map to tgz even when the compressed
      # stream itself would only be identified as plain gz.
      return extension if magic.id == "gz" && extension.id == "tgz"
      # MOBI and AZW3 share the Mobipocket container; the extension disambiguates.
      return extension if magic.id == "mobi" && extension.id == "azw3"

      # Textual extensions win over textual magic (for example a .txt file
      # containing something that looks like HTML stays txt). Binary magic
      # always wins over the extension and reports the conflict.
      if TEXTUAL_FORMATS.include?(extension.id) && TEXTUAL_FORMATS.include?(magic.id)
        return extension
      end

      warnings << format_mismatch(magic, extension)
      magic
    end

    def format_mismatch(magic, extension)
      {
        "code" => "format_mismatch",
        "message" => "File content looks like #{magic.id} but the extension says " \
                     "#{extension.id}; using #{magic.id}."
      }
    end

    # Binary MIME magic. Container checks come first so a ZIP can be reported
    # as docx/xlsx/odt/ods/epub rather than as a plain archive.
    def magic_format(path, head)
      return zip_container_format(path) if zip_magic?(head)
      return gzip_format(path) if head.start_with?("\x1F\x8B".b)
      return @registry.format("pdf") if head.start_with?("%PDF-".b)
      return @registry.format("tar") if tar_magic?(head)
      return @registry.format("xz") if head.start_with?("\xFD7zXZ\x00".b)
      return @registry.format("bz2") if bzip2_magic?(head)

      nil
    end

    def zip_magic?(head)
      ZIP_MAGICS.any? { |magic| head.start_with?(magic) }
    end

    def tar_magic?(bytes)
      return false if bytes.nil? || bytes.bytesize < 262

      bytes.byteslice(257, 5).to_s == "ustar"
    end

    def bzip2_magic?(head)
      head.bytesize >= 4 && head.byteslice(0, 3) == "BZh" &&
        head.byteslice(3, 1).to_s.match?(/\A[1-9]\z/)
    end

    def zip_container_format(path)
      entries = zip_entry_names(path)
      if entries
        return @registry.format("docx") if entries.include?("word/document.xml")
        return @registry.format("xlsx") if entries.include?("xl/workbook.xml")

        if entries.include?("mimetype")
          mime = read_zip_entry(path, "mimetype").to_s.strip
          return @registry.format("epub") if mime == "application/epub+zip"

          odf = ODF_MIMES[mime]
          return @registry.format(odf) if odf
        end
      end

      raw = read_head(path, RAW_SEARCH_BYTES)
      return @registry.format("docx") if raw.include?("word/document.xml".b)
      return @registry.format("xlsx") if raw.include?("xl/workbook.xml".b)
      return @registry.format("epub") if raw.include?("application/epub+zip".b)

      ODF_MIMES.each do |mime, id|
        return @registry.format(id) if raw.include?(mime.b)
      end

      @registry.format("zip")
    rescue StandardError
      @registry.format("zip")
    end

    def zip_entry_names(path)
      require "zip"
      names = nil
      Zip::File.open(path) { |zip| names = zip.entries.map(&:name) }
      names
    rescue LoadError, StandardError
      nil
    end

    def read_zip_entry(path, name)
      require "zip"
      content = nil
      Zip::File.open(path) do |zip|
        entry = zip.find_entry(name)
        content = entry.get_input_stream.read if entry
      end
      content
    rescue LoadError, StandardError
      nil
    end

    def gzip_format(path)
      data = Zlib::GzipReader.open(path) { |gz| gz.read(1024) }
      return @registry.format("tgz") if tar_magic?(data)

      @registry.format("gz")
    rescue StandardError
      @registry.format("gz")
    end

    def mime_format(path)
      require "marcel"
      mime = File.open(path, "rb") { |io| Marcel::MimeType.for(io) }.to_s
      mime = mime.split(";").first.to_s.strip.downcase
      return nil if mime.empty? || GENERIC_MIMES.include?(mime)

      @registry.format_for_mime(mime)
    rescue LoadError, StandardError
      nil
    end

    def sniff_format(path)
      text = read_text(path)
      return nil unless text

      best = nil
      best_score = MIN_TEXT_CONFIDENCE

      text_candidates(text).each do |id, score|
        next unless score >= MIN_TEXT_CONFIDENCE
        next unless score > best_score || (best.nil? && score == best_score)

        best = id
        best_score = score
      end

      best && @registry.format(best)
    end

    def read_text(path)
      raw = File.binread(path, SNIFF_BYTES)
      return nil if raw.nil? || raw.empty?

      sample = raw.byteslice(0, 8192)
      return nil if sample.include?("\x00".b)

      non_printable = sample.each_byte.count { |byte| byte < 9 || (byte > 13 && byte < 32) }
      return nil if non_printable > sample.bytesize * 0.1

      text = raw.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      text.delete_prefix("\uFEFF")
    rescue StandardError
      nil
    end

    # Ordered candidates with a confidence score. The first candidate reaching
    # the highest score wins, which keeps sniffing deterministic.
    def text_candidates(text)
      stripped = text.lstrip
      candidates = []

      candidates << ["vtt", 0.97] if stripped.start_with?("WEBVTT")
      candidates << ["ass", 0.95] if ass?(text)
      candidates << ["srt", 0.92] if srt?(text)
      candidates << ["svg", 0.92] if svg?(text)
      candidates << ["html", 0.90] if html?(text)
      candidates << ["xml", 0.78] if xml?(text)
      candidates << ["json", 0.98] if json?(stripped)
      candidates << ["jsonl", 0.94] if jsonl?(text)
      candidates << ["yaml", yaml_score(stripped)]
      candidates << ["toml", toml_score(text)]
      candidates << ["csv", csv_score(text, ",")]
      candidates << ["tsv", csv_score(text, "\t")]
      candidates << ["md", markdown_score(text)]

      candidates.compact
    end

    def ass?(text)
      text.match?(/^\s*\[Script Info\]/i) || text.match?(/^\s*Dialogue:/i)
    end

    def srt?(text)
      text.match?(/\d{1,2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2},\d{3}/)
    end

    def svg?(text)
      text.match?(/<svg[\s>]/i) && text.match?(/\A(?:<\?xml|<!DOCTYPE|<svg)/i)
    end

    def html?(text)
      text.match?(/<!DOCTYPE\s+html/i) || text.match?(/<html[\s>]/i) ||
        text.match?(/<head[\s>]/i)
    end

    def xml?(text)
      text.match?(/\A<\?xml/i) ||
        (text.match?(/\A<[A-Za-z_][\w:.-]*[\s>]/) && text.match?(%r{</[A-Za-z_][\w:.-]*>}))
    end

    def json?(text)
      return false unless text.start_with?("{", "[")

      JSON.parse(text)
      true
    rescue JSON::ParserError, TypeError
      false
    end

    def jsonl?(text)
      lines = text.lines.map(&:strip).reject(&:empty?)
      return false if lines.size < 2

      lines.all? do |line|
        line.start_with?("{", "[") && begin
          JSON.parse(line)
          true
        rescue JSON::ParserError, TypeError
          false
        end
      end
    end

    def yaml_score(text)
      return 0.0 if text.empty?

      document_marker = text.start_with?("---")
      structure = begin
        Psych.safe_load(text, permitted_classes: [Date, Time], aliases: true)
      rescue StandardError
        nil
      end
      return 0.96 if document_marker && (structure.is_a?(Hash) || structure.is_a?(Array))
      return 0.0 unless structure.is_a?(Hash) || structure.is_a?(Array)

      first = text.each_line.find { |line| !line.strip.empty? && !line.strip.start_with?("#") }
      return 0.0 unless first && first.match?(/\A\s*(?:-\s+)?[A-Za-z0-9_.'"-]+\s*:(?:\s|\z)/)

      0.78
    end

    def toml_score(text)
      return 0.0 unless text.each_line.any? { |line| line.match?(/\A\s*\[[^\]]+\]\s*\z/) } ||
                           text.each_line.count { |line| line.match?(/\A\s*[A-Za-z0-9_.-]+\s*=/) } >= 2

      require "toml-rb"
      value = TomlRB.parse(text)
      value.is_a?(Hash) && !value.empty? ? 0.9 : 0.0
    rescue LoadError
      text.each_line.any? { |line| line.match?(/\A\s*[A-Za-z0-9_.-]+\s*=/) } ? 0.6 : 0.0
    rescue StandardError
      0.0
    end

    def csv_score(text, delimiter)
      lines = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
      return 0.0 if lines.size < 2
      return 0.0 if lines.any? { |line| line.start_with?("|") }

      sample = lines.first(10)
      widths = begin
        CSV.parse(sample.join("\n"), col_sep: delimiter).map(&:size)
      rescue CSV::MalformedCSVError
        sample.map { |line| line.split(delimiter, -1).size }
      end
      return 0.0 if widths.min < 2
      return 0.0 unless widths.uniq.size == 1

      # A tab-separated file is much less likely to be prose; commas are a
      # weaker signal on their own.
      delimiter == "\t" ? 0.8 : 0.72
    end

    def markdown_score(text)
      signals = 0
      signals += 1 if text.match?(/^\s*#+\s+\S/)
      signals += 1 if text.match?(/^\s*[-*+]\s+\S/m)
      signals += 1 if text.match?(/\[[^\]]+\]\([^)]+\)/)
      signals += 1 if text.match?(/^```/m)
      return 0.0 if signals.zero?

      signals >= 2 ? 0.75 : 0.6
    end
  end
end
