# frozen_string_literal: true

module Cvt
  # Stable error codes and their process exit codes (spec R14). Every failure
  # documented by the CLI must use one of these codes.
  module Errors
    EXIT_CODES = {
      "usage_error" => 2,
      "unknown_format" => 2,
      "unknown_backend" => 2,
      "unsupported_conversion" => 3,
      "backend_unavailable" => 4,
      "input_not_found" => 5,
      "input_unreadable" => 5,
      "format_undetected" => 5,
      "unsafe_archive" => 5,
      "input_protected" => 5,
      "output_exists" => 6,
      "output_unwritable" => 6,
      "same_file" => 6,
      "conversion_failed" => 7,
      "timeout" => 8,
      "interrupted" => 130,
      "internal_error" => 1
    }.freeze

    module_function

    def codes
      EXIT_CODES.keys
    end

    def known?(code)
      EXIT_CODES.key?(code.to_s)
    end

    def exit_code(code)
      EXIT_CODES.fetch(code.to_s) do
        raise ArgumentError, "Unknown CVT error code: #{code.inspect}"
      end
    end

    def build(code, message, hint: "", details: nil)
      Error.new(code: code, message: message, hint: hint, details: details)
    end
  end

  # A single reported failure. `hint` is always a String (empty when there is
  # no actionable advice); `details` is optional and only used by --debug.
  # Inherits from StandardError so backends can `raise Cvt::Errors.build(...)`
  # as the frozen backend contract requires.
  class Error < StandardError
    attr_reader :code, :message, :hint, :exit_code, :details

    def initialize(code:, message:, hint: "", details: nil)
      @code = code.to_s
      @exit_code = Errors.exit_code(@code)
      @message = message.to_s
      @hint = hint.to_s
      @details = details
      freeze
    end

    def to_h
      document = {
        "code" => code,
        "message" => message,
        "hint" => hint,
        "exit_code" => exit_code
      }
      document["details"] = details unless details.nil?
      document
    end
  end
end
