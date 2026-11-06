# frozen_string_literal: true

# Reference: toml-rb (MIT) https://github.com/emancu/toml-rb
# Reference: nokogiri (MIT) https://github.com/sparklemotion/nokogiri

require_relative "../backend"
require_relative "../errors"
require_relative "../adapters/data/table"

module Cvt
  # Native data backend: every pair of csv/tsv/json/jsonl/yaml/xml/toml
  # conversion through the shared table shape. No external engine is needed.
  class NativeDataBackend < Cvt::Backend
    FORMATS = Cvt::Adapters::Data::FORMATS

    id "native_data"
    kind "native"
    priority 5
    requirements []

    def available?
      true
    end

    def available_for?(from, to, _requirements = [])
      FORMATS.include?(from.to_s) && FORMATS.include?(to.to_s)
    end

    def version
      parts = %w[nokogiri toml-rb].filter_map do |name|
        spec = Gem.loaded_specs[name]
        "#{name} #{spec.version}" if spec
      end
      parts.empty? ? nil : parts.join(", ")
    end

    def convert(input, output, options = {}, _warnings = [])
      Cvt::Adapters::Data.convert(input, output, options)
    rescue Cvt::Error
      raise
    rescue StandardError => e
      raise Cvt::Errors.build(
        "conversion_failed",
        "Data conversion failed: #{e.message.to_s.lines.first.to_s.strip}",
        hint: "Check that the input matches #{options["from"].to_s.upcase} and the table shape."
      )
    end
  end
end
