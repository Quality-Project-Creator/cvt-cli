# frozen_string_literal: true

# Reference: roo (MIT) https://github.com/roo-rb/roo
# Reference: caxlsx (MIT) https://github.com/caxlsx/caxlsx

require "date"
require "json"

require_relative "table"

module Cvt
  module Adapters
    module Data
      # XLSX/ODS reading through roo and XLSX writing through caxlsx. Both
      # gems are loaded lazily so a machine that only has one of them still
      # exposes the routes that gem can serve.
      #
      # Reference: roo (MIT) https://github.com/roo-rb/roo
      # Reference: caxlsx (MIT) https://github.com/caxlsx/caxlsx
      module SpreadsheetIO
        COLUMN_WIDTH_RANGE = (8..60).freeze
        OLE_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b

        module_function

        def roo?
          require "roo"
          !defined?(Roo::Spreadsheet).nil?
        rescue LoadError
          false
        end

        # roo ships ODS support as Roo::OpenOffice (aliased as
        # Roo::LibreOffice); builds without it must not claim the ods routes.
        def ods?
          return false unless roo?

          begin
            require "roo/open_office"
            true
          rescue LoadError
            false
          end
        end

        def caxlsx?
          require "caxlsx"
          !defined?(Axlsx::Package).nil?
        rescue LoadError
          false
        end

        def read_rows(path, options, warnings)
          ensure_roo!
          Data.enforce_size!(path, options)
          ensure_readable_container!(path)
          book = Roo::Spreadsheet.open(path)
          selected = select_sheet(book, options["sheet"])
          warnings << style_loss_warning
          if book.sheets.size > 1 && options["sheet"].to_s.empty?
            warnings << multi_sheet_warning
          end

          sheet_rows(book.sheet(selected))
        rescue Cvt::Error
          raise
        rescue StandardError => e
          raise_protected_or_failed(e)
        end

        def write_xlsx(path, rows)
          ensure_caxlsx!
          Data.validate_rows!(rows)
          package = Axlsx::Package.new
          header = Data.header_for(rows)
          package.workbook.add_worksheet(name: "Sheet1") do |sheet|
            unless header.empty?
              bold = package.workbook.styles.add_style(b: true)
              sheet.add_row(header, style: bold)
            end
            rows.each do |row|
              sheet.add_row(header.map { |key| cell_for_xlsx(row[key]) })
            end
            sheet.column_widths(*column_widths(header, rows)) unless header.empty?
          end
          package.serialize(path)
        rescue Cvt::Error
          raise
        rescue StandardError => e
          raise Data.conversion_error("Unable to write XLSX: #{first_line(e.message)}",
                                      hint: "Check the table shape and the output path.")
        end

        def select_sheet(book, value)
          key = value.to_s
          return 0 if key.empty?

          if key.match?(/\A\d+\z/)
            index = key.to_i
            unless index >= 1 && index <= book.sheets.size
              raise Data.conversion_error(
                "Worksheet index out of range: #{key}",
                hint: "The workbook has #{book.sheets.size} sheet(s): #{book.sheets.join(', ')}."
              )
            end
            return index - 1
          end

          found = book.sheets.index(key)
          unless found
            raise Data.conversion_error(
              "Worksheet not found: #{key}",
              hint: "Available sheets: #{book.sheets.join(', ')}."
            )
          end
          found
        end

        def sheet_rows(sheet)
          last_row = sheet.last_row.to_i
          return [] if last_row < 1

          header_values = Array(sheet.row(1))
          width = [header_values.length, sheet.last_column.to_i].max
          headers = (0...width).map do |index|
            name = header_values[index].to_s.strip
            name.empty? ? "column#{index + 1}" : name
          end

          (2..last_row).map do |number|
            values = Array(sheet.row(number))
            headers.each_with_index.to_h { |header, index| [header, cell_value(values[index])] }
          end
        end

        def cell_value(value)
          case value
          when Date, DateTime, Time then Data.iso8601(value)
          else value
          end
        end

        def cell_for_xlsx(value)
          case value
          when nil, String, Integer, Float, true, false then value
          when Date, DateTime, Time then Data.iso8601(value)
          when Hash, Array then JSON.generate(Data.json_safe(value))
          else
            value.respond_to?(:iso8601) ? Data.iso8601(value) : value.to_s
          end
        end

        def column_widths(header, rows)
          header.map do |name|
            widest = [name.length, *rows.map { |row| Data.cell(row[name]).length }].max
            widest.clamp(COLUMN_WIDTH_RANGE.min, COLUMN_WIDTH_RANGE.max)
          end
        end

        def ensure_roo!
          return if roo?

          raise Cvt::Errors.build(
            "backend_unavailable",
            "The roo gem is required to read spreadsheets",
            hint: "Install the cvt-cli dependencies with bundle install, then run cvt --doctor."
          )
        end

        def ensure_caxlsx!
          return if caxlsx?

          raise Cvt::Errors.build(
            "backend_unavailable",
            "The caxlsx gem is required to write XLSX files",
            hint: "Install the cvt-cli dependencies with bundle install, then run cvt --doctor."
          )
        end

        def ensure_readable_container!(path)
          magic = File.binread(path, OLE_MAGIC.bytesize).to_s.b
          return unless magic == OLE_MAGIC

          raise Cvt::Errors.build(
            "input_protected",
            "Spreadsheet is encrypted or uses an unsupported legacy format",
            hint: "Remove the password protection or save it as an unencrypted XLSX file."
          )
        rescue Errno::ENOENT, Errno::EACCES, IOError
          nil
        end

        def raise_protected_or_failed(error)
          message = error.message.to_s
          if message.match?(/password|encrypt|protect/i)
            raise Cvt::Errors.build(
              "input_protected",
              "Spreadsheet is password protected",
              hint: "Remove the password protection before converting."
            )
          end

          raise Data.conversion_error(
            "Unable to read spreadsheet: #{first_line(message)}",
            hint: "Check that the file is a valid XLSX or ODS workbook."
          )
        end

        def style_loss_warning
          {
            "code" => "style_loss",
            "message" => "Spreadsheet styles, merged cells, and macros are not preserved."
          }
        end

        def multi_sheet_warning
          {
            "code" => "multi_sheet_ignored",
            "message" => "Only the first worksheet was read; pass --sheet to choose another sheet."
          }
        end

        def first_line(message)
          message.to_s.lines.first.to_s.strip
        end
      end
    end
  end
end
