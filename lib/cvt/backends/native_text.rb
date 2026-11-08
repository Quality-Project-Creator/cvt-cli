# frozen_string_literal: true

# Reference: kramdown (MIT) https://github.com/gettalong/kramdown
# Reference: nokogiri (MIT) https://github.com/sparklemotion/nokogiri

require "cgi"
require "kramdown"
require "nokogiri"

require_relative "../backend"
require_relative "../errors"

module Cvt
  module Backends
    # Plain-text conversions that need no external engine: Markdown rendering
    # with kramdown and text extraction with Nokogiri. Output is always UTF-8
    # with LF line endings, matching the CLI contract.
    class NativeText < Cvt::Backend
      id "native_text"
      kind "native"
      priority 5
      requirements []

      SUPPORTED_PAIRS = [
        %w[md html],
        %w[md txt],
        %w[txt md],
        %w[txt html],
        %w[html txt]
      ].freeze

      BLOCK_ELEMENTS = %w[
        address article aside blockquote dd div dl dt fieldset figcaption
        figure footer form h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre
        section table tr ul
      ].freeze

      def available?
        true
      end

      def available_for?(from, to, _requirements = [])
        SUPPORTED_PAIRS.include?([from.to_s, to.to_s])
      end

      def version
        defined?(Kramdown::VERSION) ? Kramdown::VERSION : nil
      end

      def convert(input, output, options = {}, warnings = [])
        from = options["from"].to_s
        to = options["to"].to_s
        unless SUPPORTED_PAIRS.include?([from, to])
          raise Cvt::Errors.build(
            "unsupported_conversion",
            "native_text cannot convert #{from} to #{to}",
            hint: "Use cvt --formats to see supported text conversions."
          )
        end

        text = read_text(input, options)
        result = case [from, to]
                 when %w[md html] then markdown_to_html(text)
                 when %w[md txt] then html_to_text(markdown_to_html(text))
                 when %w[txt md] then text
                 when %w[txt html] then text_to_html(text)
                 when %w[html txt] then html_to_text(text)
                 end
        write_text(output, result)
        warnings
      end

      private

      def read_text(path, options)
        name = options["encoding"].to_s
        name = "UTF-8" if name.empty?
        encoding = begin
          Encoding.find(name)
        rescue ArgumentError
          raise Cvt::Errors.build(
            "input_unreadable",
            "Unknown input encoding: #{name}",
            hint: "Pass a valid --encoding name such as UTF-8."
          )
        end

        raw = File.binread(path)
        text = raw.force_encoding(encoding)
        unless text.valid_encoding?
          raise Cvt::Errors.build(
            "input_unreadable",
            "Input file is not valid #{encoding.name}",
            hint: "Pass --encoding with the encoding the file actually uses."
          )
        end
        text.encode(Encoding::UTF_8)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Cvt::Errors.build(
          "input_unreadable",
          "Unable to read input file: #{e.message}",
          hint: "Check that the file exists and is readable."
        )
      end

      def write_text(path, text)
        File.binwrite(path, text.to_s.encode(Encoding::UTF_8).gsub(/\r\n?/, "\n"))
      end

      def markdown_to_html(text)
        Kramdown::Document.new(translate_fences(text), input: "kramdown").to_html
      end

      # kramdown understands only ~~~ fences; a CommonMark ``` fence becomes an
      # inline code span and the code block is lost. Fences already using
      # tildes are left alone, as are ``` lines inside a ~~~ block.
      def translate_fences(text)
        fence = nil
        text.gsub(/^([ \t]{0,3})(`{3,}|~{3,})([^\r\n]*)/) do
          prefix, marker, rest = Regexp.last_match.captures
          if fence.nil?
            fence = marker[0]
          elsif marker[0] == fence
            fence = nil
          else
            next Regexp.last_match[0]
          end
          "#{prefix}#{'~' * marker.length}#{rest}"
        end
      end

      def text_to_html(text)
        paragraphs = text.gsub(/\r\n?/, "\n").split(/\n{2,}/).map(&:strip).reject(&:empty?)
        return "" if paragraphs.empty?

        body = paragraphs.map do |paragraph|
          "<p>#{CGI.escapeHTML(paragraph).gsub("\n", "<br>")}</p>"
        end.join("\n")
        "#{body}\n"
      end

      def html_to_text(html)
        document = Nokogiri::HTML(html.to_s)
        root = document.at("body") || document
        buffer = +""
        append_text(root, buffer)
        normalize_text(buffer)
      end

      def append_text(node, buffer)
        node.children.each do |child|
          if child.text?
            buffer << child.text
          elsif child.element?
            name = child.name.downcase
            if name == "br"
              buffer << "\n"
              next
            end

            block = BLOCK_ELEMENTS.include?(name)
            buffer << "\n" if block && !buffer.empty? && !buffer.end_with?("\n\n")
            append_text(child, buffer)
            buffer << "\n" if block
          end
        end
      end

      def normalize_text(text)
        normalized = text.gsub(/\u00A0/, " ").gsub(/\r\n?/, "\n")
        normalized = normalized.split("\n").map(&:rstrip).join("\n")
        normalized = normalized.sub(/\A\n+/, "").gsub(/\n{3,}/, "\n\n").sub(/\n+\z/, "")
        normalized.empty? ? "" : "#{normalized}\n"
      end
    end
  end
end
