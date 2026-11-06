# frozen_string_literal: true

require "psych"
require_relative "version"
require_relative "errors"

module Cvt
  # Builds the stable YAML documents described by spec R2.
  #
  # Rules enforced here:
  # - top-level keys are Strings and appear in a fixed order;
  # - no YAML document marker, no Ruby object tags, no symbol keys;
  # - cycles and objects that cannot be safely serialized are rejected;
  # - output is UTF-8 with LF line endings.
  module YAMLOutput
    class InvalidDocument < StandardError; end

    module_function

    def success(operation:, version: Cvt::VERSION, input: nil, output: nil, route: [],
                options: {}, timing: {}, warnings: [])
      dump(success_document(operation: operation, version: version, input: input,
                            output: output, route: route, options: options,
                            timing: timing, warnings: warnings))
    end

    def success_document(operation:, version: Cvt::VERSION, input: nil, output: nil,
                         route: [], options: {}, timing: {}, warnings: [])
      document = {
        "ok" => true,
        "version" => version,
        "operation" => operation
      }
      document["input"] = input unless input.nil?
      document["output"] = output unless output.nil?
      document["route"] = Array(route).map do |step|
        step.is_a?(Hash) ? step : step.to_h
      end
      document["options"] = options
      document["timing"] = timing
      document["warnings"] = normalize_warnings(warnings)
      document
    end

    def failure(operation:, error:, version: Cvt::VERSION, input: nil, output: nil,
                warnings: [])
      dump(failure_document(operation: operation, error: error, version: version,
                            input: input, output: output, warnings: warnings))
    end

    def failure_document(operation:, error:, version: Cvt::VERSION, input: nil,
                         output: nil, warnings: [])
      document = {
        "ok" => false,
        "version" => version,
        "operation" => operation,
        "error" => normalize_error(error)
      }
      document["input"] = input unless input.nil?
      document["output"] = output unless output.nil?
      document["warnings"] = normalize_warnings(warnings)
      document
    end

    # Ordered input section used by convert/plan documents.
    def input(path:, format:, bytes: nil)
      section = { "path" => path, "format" => format }
      section["bytes"] = bytes unless bytes.nil?
      section
    end

    # Ordered output section used by convert/plan documents.
    def output(path:, format:, bytes: nil)
      section = { "path" => path, "format" => format }
      section["bytes"] = bytes unless bytes.nil?
      section
    end

    def dump(document)
      validate!(document)
      yaml = Psych.dump(deep_copy(document), line_width: -1)
      yaml = yaml.encode(Encoding::UTF_8).gsub(/\r\n?/, "\n")
      yaml.delete_prefix("---\n")
    end

    # Psych emits anchors/aliases for repeated Hash or Array objects, which
    # many safe_load callers reject. Copying containers keeps output plain and
    # free of YAML aliases.
    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[key] = deep_copy(child) }
      when Array
        value.map { |child| deep_copy(child) }
      else
        value
      end
    end

    def normalize_warnings(warnings)
      Array(warnings).map do |warning|
        hash = warning.respond_to?(:to_h) ? warning.to_h : warning
        unless hash.is_a?(Hash)
          raise InvalidDocument, "warning must be a Hash with code and message"
        end
        code = hash["code"] || hash[:code]
        message = hash["message"] || hash[:message]
        if code.nil? || message.nil?
          raise InvalidDocument, "warning must contain code and message"
        end
        { "code" => code.to_s, "message" => message.to_s }
      end
    end

    def normalize_error(error)
      return error.to_h if error.is_a?(Error)
      unless error.is_a?(Hash)
        raise InvalidDocument, "error must be a Cvt::Error or Hash"
      end

      code = error["code"] || error[:code]
      message = error["message"] || error[:message]
      hint = error["hint"] || error[:hint] || ""
      details = error["details"] || error[:details]
      raise InvalidDocument, "error must contain code and message" if code.nil? || message.nil?

      document = {
        "code" => code.to_s,
        "message" => message.to_s,
        "hint" => hint.to_s,
        "exit_code" => Errors.exit_code(code)
      }
      document["details"] = details unless details.nil?
      document
    end

    def validate!(value, path = "document", seen = {})
      case value
      when Hash
        with_node(value, path, seen) do
          value.each do |key, child|
            raise InvalidDocument, "#{path} has a non-String key" unless key.is_a?(String)
            validate!(child, "#{path}.#{key}", seen)
          end
        end
      when Array
        with_node(value, path, seen) do
          value.each_with_index { |child, index| validate!(child, "#{path}[#{index}]", seen) }
        end
      when String, Integer, true, false, nil
        nil
      when Float
        raise InvalidDocument, "#{path} contains a non-finite Float" unless value.finite?
      else
        raise InvalidDocument, "#{path} contains unsupported #{value.class}"
      end
    end

    def with_node(object, path, seen)
      object_id = object.object_id
      raise InvalidDocument, "#{path} contains a circular reference" if seen[object_id]

      seen[object_id] = true
      begin
        yield
      ensure
        seen.delete(object_id)
      end
    end
  end
end
