# frozen_string_literal: true

# Reference: pdf-reader (MIT) https://github.com/yob/pdf-reader
# Reference: Poppler (GPL-2.0+) https://poppler.freedesktop.org/
require_relative "../../errors"
require_relative "poppler"

module Cvt
  module Adapters
    module Pdf
      # Extracts PDF text with pdf-reader first and falls back to Poppler's
      # pdftotext when the gem is missing or cannot parse the file. `page`
      # selects a single page; nil means every page.
      class TextExtractor
        def initialize(input, page: nil, timeout: 0, pdftotext: Poppler.pdftotext)
          @input = input
          @page = page
          @timeout = timeout
          @pdftotext = pdftotext
          @reader_error = nil
        end

        def extract
          text = reader_text
          return normalize(text) unless text.nil?

          text = poppler_text
          normalize(text)
        end

        private

        def reader_text
          require "pdf-reader"
          reader = PDF::Reader.new(@input)
          if @page
            if @page > reader.page_count
              raise Cvt::Errors.build(
                "conversion_failed",
                "PDF has only #{reader.page_count} page(s); page #{@page} does not exist",
                hint: "Choose a page between 1 and #{reader.page_count}."
              )
            end
            reader.page(@page).text
          else
            reader.pages.map(&:text).join("\n")
          end
        rescue LoadError
          nil
        rescue StandardError => e
          raise Poppler.protected_error if encrypted?(e)

          @reader_error = e
          nil
        end

        def encrypted?(error)
          error.class.name.to_s.include?("Encrypted") || error.message.to_s.match?(/encrypt|password/i)
        end

        def poppler_text
          unless @pdftotext
            raise Cvt::Errors.build(
              "conversion_failed", "Could not extract text from the PDF",
              hint: "Poppler pdftotext is not installed; install Poppler and retry, or " \
                    "check that the PDF is not damaged.",
              details: @reader_error && { "stderr" => @reader_error.message }
            )
          end

          Poppler.extract_text(@input, page: @page, timeout: @timeout)
        end

        def normalize(text)
          text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
              .gsub("\r\n", "\n").gsub("\f", "\n").delete("\r")
        end
      end
    end
  end
end
