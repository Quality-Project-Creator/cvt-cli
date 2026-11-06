# frozen_string_literal: true

# Reference: roo (MIT) https://github.com/roo-rb/roo
# Reference: caxlsx (MIT) https://github.com/caxlsx/caxlsx

require_relative "../backend"
require_relative "../errors"
require_relative "../adapters/data/table"
require_relative "../adapters/data/spreadsheet_io"

module Cvt
  # Spreadsheet backend: XLSX/ODS reading through roo, XLSX writing through
  # caxlsx, and data-format output through the shared table adapter.
  class SpreadsheetBackend < Cvt::Backend
    READ_FORMATS = %w[xlsx ods].freeze
    WRITE_FORMAT = "xlsx"

    id "spreadsheet"
    kind "gem"
    priority 8
    requirements []

    def available?
      Cvt::Adapters::Data::SpreadsheetIO.roo? || Cvt::Adapters::Data::SpreadsheetIO.caxlsx?
    end

    def available_for?(from, to, _requirements = [])
      from = from.to_s
      to = to.to_s
      io = Cvt::Adapters::Data::SpreadsheetIO

      if READ_FORMATS.include?(from)
        return false unless io.roo?
        return false if from == "ods" && !io.ods?

        return io.caxlsx? if to == WRITE_FORMAT

        Cvt::Adapters::Data::FORMATS.include?(to)
      else
        Cvt::Adapters::Data::FORMATS.include?(from) && to == WRITE_FORMAT && io.caxlsx?
      end
    end

    def version
      io = Cvt::Adapters::Data::SpreadsheetIO
      io.roo?
      io.caxlsx?
      parts = %w[roo caxlsx].filter_map do |name|
        spec = Gem.loaded_specs[name]
        "#{name} #{spec.version}" if spec
      end
      parts.empty? ? nil : parts.join(", ")
    end

    def convert(input, output, options = {}, warnings = [])
      from = options["from"].to_s
      to = options["to"].to_s
      if READ_FORMATS.include?(from)
        rows = Cvt::Adapters::Data::SpreadsheetIO.read_rows(input, options, warnings)
        if to == WRITE_FORMAT
          Cvt::Adapters::Data::SpreadsheetIO.write_xlsx(output, rows)
        else
          Cvt::Adapters::Data.write(output, rows, options)
        end
      else
        rows = Cvt::Adapters::Data.read(input, options)
        Cvt::Adapters::Data::SpreadsheetIO.write_xlsx(output, rows)
      end
    rescue Cvt::Error
      raise
    rescue StandardError => e
      raise Cvt::Errors.build(
        "conversion_failed",
        "Spreadsheet conversion failed: #{e.message.to_s.lines.first.to_s.strip}",
        hint: "Check that the input is a valid spreadsheet and the table shape is supported."
      )
    end
  end
end
