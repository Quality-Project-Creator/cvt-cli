# frozen_string_literal: true

require_relative "version"
require_relative "errors"
require_relative "yaml_output"

module Cvt
  # Outcome of a CLI operation. A Result knows whether it succeeded, keeps the
  # ordered fields for the YAML contract, and exposes the process exit code.
  class Result
    attr_reader :operation, :input, :output, :route, :options, :timing, :warnings, :error

    def self.success(operation:, input: nil, output: nil, route: [], options: {},
                     timing: {}, warnings: [])
      new(ok: true, operation: operation, input: input, output: output, route: route,
          options: options, timing: timing, warnings: warnings)
    end

    def self.failure(operation:, error: nil, code: nil, message: nil, hint: "", input: nil,
                     output: nil, warnings: [])
      error ||= Errors.build(code, message, hint: hint)
      unless error.is_a?(Error)
        raise ArgumentError, "error must be a Cvt::Error"
      end

      new(ok: false, operation: operation, input: input, output: output, route: [],
          options: {}, timing: {}, warnings: warnings, error: error)
    end

    def initialize(ok:, operation:, input: nil, output: nil, route: [], options: {},
                   timing: {}, warnings: [], error: nil)
      @ok = ok
      @operation = operation.to_s
      @input = input
      @output = output
      @route = route
      @options = options
      @timing = timing
      @warnings = warnings
      @error = error
    end

    def ok?
      @ok
    end

    def failure?
      !@ok
    end

    def exit_code
      ok? ? 0 : error.exit_code
    end

    def route_steps
      Array(route).map { |step| step.is_a?(Hash) ? step : step.to_h }
    end

    def to_h
      if ok?
        YAMLOutput.success_document(operation: operation, input: input, output: output,
                                    route: route_steps, options: options, timing: timing,
                                    warnings: warnings)
      else
        YAMLOutput.failure_document(operation: operation, error: error, input: input,
                                    output: output, warnings: warnings)
      end
    end

    def to_yaml
      YAMLOutput.dump(to_h)
    end
  end
end
