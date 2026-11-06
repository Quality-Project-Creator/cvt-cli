# frozen_string_literal: true

# Reference: toml-rb (MIT) https://github.com/emancu/toml-rb
# Reference: nokogiri (MIT) https://github.com/sparklemotion/nokogiri

require "csv"
require "date"
require "json"
require "nokogiri"
require "time"
require "toml-rb"
require "yaml"

require_relative "../../errors"

module Cvt
  module Adapters
    # Table shape ("rows": an Array of Hash records) and the textual data
    # formats around it. CSV/TSV, JSON/JSONL, YAML, TOML, and XML all parse
    # into the same shape so every data pair shares one implementation.
    #
    # Reference: toml-rb (MIT) https://github.com/emancu/toml-rb
    # Reference: nokogiri (MIT) https://github.com/sparklemotion/nokogiri
    module Data
      FORMATS = %w[csv tsv json jsonl yaml xml toml].freeze
      TABLE_FORMATS = %w[csv tsv jsonl].freeze
      DEFAULT_MAX_SIZE = 1024**3
      DEFAULT_ROOT = "rows"
      DEFAULT_ENCODING = "UTF-8"
      TOML_ESCAPES = {
        "\\" => "\\\\", "\"" => "\\\"", "\b" => "\\b", "\t" => "\\t",
        "\n" => "\\n", "\f" => "\\f", "\r" => "\\r"
      }.freeze

      module_function

      def normalize_format(value)
        format = value.to_s.downcase
        return format if FORMATS.include?(format)

        raise conversion_error("Unsupported data format: #{value}",
                               hint: "Use one of: #{FORMATS.join(', ')}.")
      end

      # Reads a file into table shape. format comes from options["from"].
      def read(path, options = {})
        format = normalize_format(options["from"])
        return read_jsonl_file(path, options) if format == "jsonl"

        content = read_text(path, options)
        parse(format, content, options)
      end

      # Writes table shape to a file. format comes from options["to"].
      def write(path, rows, options = {})
        format = normalize_format(options["to"])
        validate_rows!(rows)
        if format == "jsonl"
          write_jsonl(path, rows)
        else
          File.binwrite(path, ensure_lf(serialize(format, rows, options)))
        end
      end

      # Full data-pair conversion. Table-shaped sources feed the table path;
      # json/yaml/xml/toml preserve their tree for tree-capable targets.
      def convert(input, output, options = {})
        from = normalize_format(options["from"])
        to = normalize_format(options["to"])

        if TABLE_FORMATS.include?(to) || TABLE_FORMATS.include?(from)
          write(output, read(input, options), options)
        elsif %w[json yaml].include?(to)
          write_tree(output, read_tree(input, from, options), to, options)
        else
          value = read_tree(input, from, options)
          if %w[toml xml].include?(to) && table_shape?(value)
            write(output, table_from_tree(value, from.upcase), options)
          else
            write_tree(output, value, to, options)
          end
        end
      end

      def read_tree(path, from, options = {})
        content = read_text(path, options)
        case from
        when "json" then parse_json_value(content)
        when "yaml" then parse_yaml_value(content)
        when "toml" then parse_toml_value(content)
        when "xml" then parse_xml_tree(content)
        else
          raise conversion_error("#{from.upcase} input cannot be read as a tree",
                                 hint: "Use a JSON, YAML, TOML, or XML input.")
        end
      end

      def write_tree(path, value, to, options = {})
        format = normalize_format(to)
        text = case format
               when "json" then "#{JSON.pretty_generate(json_safe(value))}\n"
               when "yaml" then YAML.dump(json_safe(value))
               when "xml" then serialize_xml_tree(value, options)
               when "toml" then serialize_toml_tree(value)
               else
                 raise conversion_error("#{format.upcase} output requires table-shaped data",
                                        hint: "Use CSV, TSV, JSONL, or an array of objects.")
               end
        File.binwrite(path, ensure_lf(text))
      end

      # A JSON/YAML value is table-shaped when it is an array of objects, or
      # an object with exactly one array-of-objects field.
      def table_shape?(value)
        case value
        when Array
          value.all? { |item| item.is_a?(Hash) }
        when Hash
          value.size == 1 && value.values.first.is_a?(Array) &&
            value.values.first.all? { |item| item.is_a?(Hash) }
        else
          false
        end
      end

      def parse(format, content, options = {})
        case format
        when "csv" then parse_delimited(content, delimiter(options))
        when "tsv" then parse_delimited(content, "\t")
        when "json" then parse_json(content)
        when "jsonl" then parse_jsonl(content)
        when "yaml" then parse_yaml(content)
        when "toml" then parse_toml(content, options)
        when "xml" then parse_xml(content, options)
        else normalize_format(format)
        end
      end

      def serialize(format, rows, options = {})
        validate_rows!(rows)
        case format
        when "csv" then serialize_delimited(rows, delimiter(options))
        when "tsv" then serialize_delimited(rows, "\t")
        when "json" then "#{JSON.pretty_generate(json_safe(rows))}\n"
        when "jsonl" then serialize_jsonl(rows)
        when "yaml" then YAML.dump(json_safe(rows))
        when "toml" then serialize_toml(rows, options)
        when "xml" then serialize_xml(rows, options)
        else normalize_format(format)
        end
      end

      # Header order for delimited/spreadsheet exports: field union in
      # first-seen order across all rows (spec R8, JSON -> CSV).
      def header_for(rows)
        seen = {}
        rows.each_with_object([]) do |row, keys|
          row.each_key do |key|
            name = key.to_s
            next if seen[name]

            seen[name] = true
            keys << name
          end
        end
      end

      def read_text(path, options = {})
        enforce_size!(path, options)
        bytes = File.binread(path)
        encoding_name = input_encoding(options)
        source = Encoding.find(encoding_name)
        text = bytes.force_encoding(source)
        unless text.valid_encoding?
          raise input_unreadable_error("Input is not valid #{encoding_name}",
                                       hint: "Pass --encoding with the file's actual encoding.")
        end

        text.encode(Encoding::UTF_8).delete_prefix("\uFEFF")
      rescue ArgumentError
        raise input_unreadable_error("Unknown input encoding: #{encoding_name}",
                                     hint: "Pass --encoding with a valid encoding name such as UTF-8.")
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise input_unreadable_error("Input cannot be decoded as #{encoding_name}",
                                     hint: "Pass --encoding with the file's actual encoding.")
      end

      def input_encoding(options)
        name = options["encoding"].to_s
        name.empty? ? DEFAULT_ENCODING : name
      end

      def enforce_size!(path, options)
        limit = max_size(options)
        return if limit <= 0

        size = File.size(path)
        return if size <= limit

        raise conversion_error(
          "Input is #{size} bytes, which exceeds the --max-size limit of #{limit} bytes",
          hint: "Increase --max-size or convert a smaller file."
        )
      end

      def max_size(options)
        value = options["max_size"]
        value.nil? ? DEFAULT_MAX_SIZE : value.to_i
      end

      def delimiter(options)
        value = options["delimiter"].to_s
        value.empty? ? "," : value
      end

      def root_key(options)
        key = options["root"].to_s
        key.empty? ? DEFAULT_ROOT : key
      end

      def conversion_error(message, hint: "")
        Cvt::Errors.build("conversion_failed", message, hint: hint)
      end

      def input_unreadable_error(message, hint: "")
        Cvt::Errors.build("input_unreadable", message, hint: hint)
      end

      def validate_rows!(rows)
        unless rows.is_a?(Array)
          raise conversion_error("Table data must be an array of objects",
                                 hint: "Use a top-level array of objects.")
        end

        rows.each_with_index do |row, index|
          next if row.is_a?(Hash)

          raise conversion_error("Row #{index + 1} is not an object",
                                 hint: "Every table row must be an object with named fields.")
        end
        rows
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def parse_delimited(content, separator)
        table = CSV.parse(content, headers: true, col_sep: separator, row_sep: :auto,
                                   skip_blanks: true)
        table.map do |row|
          values = stringify_keys(row.to_h)
          values.each { |key, value| values[key] = "" if value.nil? }
          values
        end
      rescue CSV::MalformedCSVError => e
        raise conversion_error("Invalid CSV: #{first_line(e.message)}",
                               hint: "Check quoting and the --delimiter option.")
      end

      def parse_json(content)
        table_from_tree(parse_json_value(content), "JSON")
      end

      def parse_json_value(content)
        JSON.parse(content)
      rescue JSON::ParserError => e
        raise conversion_error("Invalid JSON: #{first_line(e.message)}",
                               hint: "Check the JSON syntax.")
      end

      def parse_yaml(content)
        table_from_tree(parse_yaml_value(content), "YAML")
      end

      def parse_yaml_value(content)
        ensure_single_yaml_document!(content)
        Psych.safe_load(content, permitted_classes: [Date, Time], aliases: true)
      rescue Psych::Exception => e
        raise conversion_error("Invalid YAML: #{first_line(e.message)}",
                               hint: "Use a single YAML document with plain mappings or sequences.")
      end

      def ensure_single_yaml_document!(content)
        documents = Psych.parse_stream(content).children
        return if documents.size <= 1

        raise conversion_error("YAML input contains multiple documents",
                               hint: "Keep exactly one YAML document per file.")
      end

      def parse_toml(content, options)
        data = parse_toml_value(content)
        root = root_key(options)
        records = data[root]
        unless records.is_a?(Array)
          raise conversion_error("TOML root key #{root.inspect} must be an array of tables",
                                 hint: "Use [[#{root}]] table arrays, or pass --root to name the root key.")
        end

        table_from_records(records, "TOML")
      end

      def parse_toml_value(content)
        TomlRB.parse(content)
      rescue TomlRB::Error => e
        raise conversion_error("Invalid TOML: #{first_line(e.message)}",
                               hint: "Check TOML table headers and values.")
      end

      def table_from_tree(value, label)
        records = case value
                  when Array then value
                  when Hash
                    value.size == 1 && value.values.first.is_a?(Array) ? value.values.first : nil
                  end
        unless records
          raise conversion_error("#{label} input must be an array of objects",
                                hint: "#{label} input must be a top-level array of objects, " \
                                      "or an object with a single array key.")
        end

        table_from_records(records, label)
      end

      def table_from_records(records, label)
        records.each_with_index do |record, index|
          next if record.is_a?(Hash)

          raise conversion_error("#{label} record #{index + 1} must be an object",
                                 hint: "Every record must map field names to values.")
        end
        records.map { |record| stringify_keys(record) }
      end

      def parse_jsonl(content)
        rows = []
        content.each_line.with_index(1) do |line, number|
          record = parse_jsonl_line(line, number)
          rows << record if record
        end
        rows
      end

      # JSONL is processed one line per record instead of loading every
      # record at once; the total input is still bounded by --max-size.
      def read_jsonl_file(path, options)
        enforce_size!(path, options)
        encoding_name = input_encoding(options)
        begin
          Encoding.find(encoding_name)
        rescue ArgumentError
          raise input_unreadable_error("Unknown input encoding: #{encoding_name}",
                                       hint: "Pass --encoding with a valid encoding name such as UTF-8.")
        end

        rows = []
        File.open(path, "r:#{encoding_name}:UTF-8") do |io|
          io.each_line.with_index(1) do |line, number|
            record = parse_jsonl_line(line, number)
            rows << record if record
          end
        end
        rows
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise input_unreadable_error("Input cannot be decoded as #{input_encoding(options)}",
                                     hint: "Pass --encoding with the file's actual encoding.")
      end

      def parse_jsonl_line(line, number)
        unless line.valid_encoding?
          raise input_unreadable_error("Input contains invalid bytes",
                                       hint: "Pass --encoding with the file's actual encoding.")
        end

        text = line.delete_prefix("\uFEFF").strip
        return nil if text.empty?

        begin
          record = JSON.parse(text)
        rescue JSON::ParserError => e
          raise conversion_error("Invalid JSON on line #{number}: #{first_line(e.message)}",
                                 hint: "Each JSONL line must be one JSON object.")
        end
        unless record.is_a?(Hash)
          raise conversion_error("JSONL record on line #{number} must be an object",
                                 hint: "Each JSONL line must be a JSON object, not an array or scalar.")
        end

        stringify_keys(record)
      end

      def parse_xml(content, options)
        document = parse_xml_document(content)
        root_name = root_key(options)
        root_node = find_root(document.root, root_name)
        unless root_node
          raise conversion_error("XML root element <#{root_name}> was not found",
                                 hint: "Pass --root to match the XML root element name.")
        end

        records = root_node.element_children
        records.map do |record|
          value = element_to_value(record, {})
          unless value.is_a?(Hash)
            raise conversion_error("XML record <#{prefixed_name(record)}> must contain fields",
                                   hint: "Use <#{root_name}><row><field>value</field></row></#{root_name}>.")
          end

          value
        end
      end

      def parse_xml_tree(content)
        document = parse_xml_document(content)
        root = document.root
        unless root
          raise conversion_error("XML input has no root element",
                                 hint: "Check that the XML is well formed.")
        end

        element_to_value(root, {})
      end

      def parse_xml_document(content)
        Nokogiri::XML(content, nil, "UTF-8") { |config| config.strict }
      rescue Nokogiri::XML::SyntaxError => e
        raise conversion_error("Invalid XML: #{first_line(e.message)}",
                               hint: "Check that the XML is well formed.")
      end

      def find_root(node, name)
        stack = [node].compact
        until stack.empty?
          current = stack.shift
          return current if current.name == name || prefixed_name(current) == name

          stack.concat(current.element_children)
        end
        nil
      end

      def element_to_value(node, seen)
        guard!(node, seen) do
          children = node.element_children
          attributes = node.attribute_nodes
          direct_text = node.children.select(&:text?).map(&:content).join
          if children.empty? && attributes.empty?
            direct_text
          else
            result = {}
            attributes.each { |attribute| result["@#{prefixed_name(attribute)}"] = attribute.value }
            text = direct_text.strip
            result["#text"] = text unless text.empty?
            children.each do |child|
              name = prefixed_name(child)
              value = element_to_value(child, seen)
              if result.key?(name)
                result[name] = [result[name]] unless result[name].is_a?(Array)
                result[name] << value
              else
                result[name] = value
              end
            end
            result
          end
        end
      end

      def prefixed_name(node)
        prefix = node.namespace&.prefix
        prefix && !prefix.empty? ? "#{prefix}:#{node.name}" : node.name
      end

      def serialize_delimited(rows, separator)
        return "" if rows.empty?

        header = header_for(rows)
        lines = [CSV.generate_line(header, col_sep: separator, row_sep: "\n")]
        rows.each do |row|
          lines << CSV.generate_line(header.map { |key| cell(row[key]) },
                                     col_sep: separator, row_sep: "\n")
        end
        lines.join
      end

      def serialize_jsonl(rows)
        return "" if rows.empty?

        rows.map { |row| JSON.generate(json_safe(row)) }.join("\n") + "\n"
      end

      def write_jsonl(path, rows)
        File.open(path, "w:UTF-8") do |io|
          rows.each do |row|
            io.write(JSON.generate(json_safe(row)))
            io.write("\n")
          end
        end
      end

      def serialize_toml(rows, options)
        root = root_key(options)
        records = toml_safe(rows)
        key = toml_key(root)
        return "#{key} = []\n" if records.empty?

        records.each_with_object(+"") do |row, output|
          output << "[[#{key}]]\n"
          row.each { |field, value| output << "#{toml_key(field)} = #{toml_value(value)}\n" }
        end
      end

      def serialize_toml_tree(value)
        unless value.is_a?(Hash)
          raise conversion_error(
            "TOML output requires a top-level object, not #{value_type(value)}",
            hint: "Convert a JSON/YAML object to TOML, or use an array of objects as a table."
          )
        end

        TomlRB.dump(toml_safe(value))
      rescue TomlRB::Error => e
        raise conversion_error("Cannot write TOML: #{first_line(e.message)}",
                               hint: "Remove null values or use JSON or YAML instead.")
      end

      def value_type(value)
        case value
        when Array then "an array"
        when Hash then "an object"
        when nil then "null"
        else "a scalar"
        end
      end

      # Written by hand instead of TomlRB.dump because the gem sorts keys; the
      # spec requires field order to survive CSV -> TOML.
      def toml_key(key)
        name = key.to_s
        return name if name.match?(/\A[a-zA-Z0-9_-]+\z/)

        toml_string(name)
      end

      def toml_value(value)
        case value
        when String then toml_string(value)
        when Integer then value.to_s
        when Float
          unless value.finite?
            raise conversion_error("TOML cannot represent non-finite numbers",
                                   hint: "Replace NaN or Infinity before converting.")
          end
          value.to_s
        when true then "true"
        when false then "false"
        when Array then "[#{value.map { |item| toml_value(item) }.join(', ')}]"
        when Hash
          pairs = value.map { |key, child| "#{toml_key(key)} = #{toml_value(child)}" }
          "{ #{pairs.join(', ')} }"
        else
          toml_string(value.to_s)
        end
      end

      def toml_string(value)
        escaped = value.to_s.gsub(/[\x00-\x1f\x7f"\\]/) do |char|
          TOML_ESCAPES[char] || format("\\u%04X", char.ord)
        end
        "\"#{escaped}\""
      end

      def toml_safe(value, path = nil, seen = {})
        case value
        when Hash
          guard!(value, seen) do
            value.each_with_object({}) do |(key, child), result|
              name = key.to_s
              child_path = path ? "#{path}.#{name}" : name
              result[name] = toml_safe(child, child_path, seen)
            end
          end
        when Array
          guard!(value, seen) { value.map { |child| toml_safe(child, path, seen) } }
        when nil
          raise conversion_error(
            "TOML cannot represent null values#{path ? " (at #{path})" : ""}",
            hint: "Remove null values or use JSON or YAML instead."
          )
        when Date, DateTime, Time
          iso8601(value)
        when String, Integer, Float, true, false
          value
        else
          value.respond_to?(:iso8601) ? iso8601(value) : value.to_s
        end
      end

      def serialize_xml(rows, options)
        write_xml_document(root_key(options)) do |document, root_node|
          rows.each do |row|
            row_node = document.create_element("row")
            append_fields(row_node, row, document, {})
            root_node.add_child(row_node)
          end
        end
      end

      def serialize_xml_tree(value, options)
        write_xml_document(root_key(options)) do |document, root_node|
          case value
          when Hash
            append_fields(root_node, value, document, {})
          when Array
            value.each { |item| append_element(root_node, "row", item, document, {}) }
          when nil
            nil
          else
            root_node.add_child(Nokogiri::XML::Text.new(scalar_text(value), document))
          end
        end
      end

      def write_xml_document(root)
        document = Nokogiri::XML::Document.new
        document.encoding = "UTF-8"
        root_node = document.create_element(root)
        yield document, root_node
        document.add_child(root_node)
        document.to_xml
      rescue Nokogiri::XML::SyntaxError, RuntimeError, ArgumentError => e
        raise conversion_error("Cannot write XML: #{first_line(e.message)}",
                               hint: "Pass --root with a valid XML element name and use valid field names.")
      end

      def append_fields(node, hash, document, seen)
        guard!(hash, seen) do
          hash.each do |key, value|
            name = key.to_s
            case name
            when "#text"
              node.add_child(Nokogiri::XML::Text.new(scalar_text(value), document))
            when /\A@/
              node[name[1..]] = scalar_text(value)
            else
              append_element(node, name, value, document, seen)
            end
          end
        end
      end

      def append_element(parent, name, value, document, seen)
        case value
        when Array
          guard!(value, seen) { value.each { |item| append_element(parent, name, item, document, seen) } }
        when Hash
          child = document.create_element(name)
          append_fields(child, value, document, seen)
          parent.add_child(child)
        when nil
          parent.add_child(document.create_element(name))
        else
          child = document.create_element(name)
          child.add_child(Nokogiri::XML::Text.new(scalar_text(value), document))
          parent.add_child(child)
        end
      end

      def json_safe(value, seen = {})
        case value
        when Hash
          guard!(value, seen) do
            value.each_with_object({}) do |(key, child), result|
              result[key.to_s] = json_safe(child, seen)
            end
          end
        when Array
          guard!(value, seen) { value.map { |child| json_safe(child, seen) } }
        when Date, DateTime, Time
          iso8601(value)
        when Symbol
          value.to_s
        when Float
          unless value.finite?
            raise conversion_error("Data contains a non-finite number",
                                   hint: "Replace NaN or Infinity before converting.")
          end
          value
        when String, Integer, true, false, nil
          value
        else
          value.respond_to?(:iso8601) ? iso8601(value) : value.to_s
        end
      end

      def cell(value)
        case value
        when nil then ""
        when String then value
        when Date, DateTime, Time then iso8601(value)
        when Hash, Array then JSON.generate(json_safe(value))
        when true then "true"
        when false then "false"
        else
          value.respond_to?(:iso8601) ? iso8601(value) : value.to_s
        end
      end

      def scalar_text(value)
        case value
        when nil then ""
        when Hash, Array then JSON.generate(json_safe(value))
        when true then "true"
        when false then "false"
        else cell(value)
        end
      end

      def iso8601(value)
        case value.class.name
        when "TomlRB::LocalDate"
          value.strftime("%Y-%m-%d")
        when "TomlRB::LocalTime"
          value.strftime("%H:%M:%S")
        when "TomlRB::LocalDateTime"
          value.strftime("%Y-%m-%dT%H:%M:%S")
        else
          value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        end
      end

      def guard!(object, seen)
        id = object.object_id
        if seen[id]
          raise conversion_error("Data contains a circular reference",
                                 hint: "Remove YAML anchors or self-references before converting.")
        end

        seen[id] = true
        begin
          yield
        ensure
          seen.delete(id)
        end
      end

      def ensure_lf(text)
        value = text.to_s.encode(Encoding::UTF_8)
        value = value.gsub("\r\n", "\n").gsub("\r", "\n")
        value << "\n" unless value.empty? || value.end_with?("\n")
        value
      end

      def first_line(message)
        message.to_s.lines.first.to_s.strip
      end
    end
  end
end
