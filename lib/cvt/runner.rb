# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "securerandom"
require "tmpdir"

require_relative "detector"
require_relative "errors"
require_relative "registry"
require_relative "result"
require_relative "router"
require_relative "shell"
require_relative "yaml_output"

module Cvt
  # Validates a conversion request, resolves the route, and performs an atomic
  # write through a same-directory temporary file. All paths handed to a
  # backend are absolute. On any failure the temporary file is removed and the
  # target is left untouched.
  class Runner
    def initialize(registry: Cvt::Registry.default, detector: nil, router: nil,
                   pool: Cvt::Backends)
      @registry = registry
      @detector = detector || Cvt::Detector.new(registry: @registry)
      @router = router || Cvt::Router.new(registry: @registry, pool: pool)
      @pool = pool
    end

    # rubocop:disable Metrics/ParameterLists
    def call(source:, target: nil, to: nil, options: {}, display_options: nil, from: nil,
             force: false, dry_run: false, debug: false)
      options = normalize_hash(options)
      display_options = normalize_hash(display_options || options)
      operation = dry_run ? "plan" : "convert"
      started = monotonic_now

      source_display = source.to_s
      return failure(operation, "usage_error", "Source path is required",
                     hint: "Run cvt --help for usage.", started: started) if source_display.empty?

      source_abs = File.expand_path(source_display)
      input_error = validate_source(source_display, source_abs)
      return failure(operation, input_error.code, input_error.message,
                     hint: input_error.hint, started: started) if input_error

      detection = @detector.detect(source_display, from: from)
      warnings = detection.warnings.dup
      input_format = detection.format
      if input_format.nil?
        return failure(operation, "format_undetected",
                       "Unable to detect the input format for #{source_display}",
                       hint: "Pass --from FORMAT to specify the input format.",
                       input: { "path" => source_display }, started: started)
      end

      target_format, target_display = resolve_target(source_display, target, to, input_format)
      if target_format.is_a?(Cvt::Error)
        return failure(operation, target_format.code, target_format.message,
                       hint: target_format.hint, input: input_section(source_display, input_format),
                       started: started)
      end

      target_abs = File.expand_path(target_display)
      input_section = input_section(source_display, input_format, bytes: File.size(source_abs))
      output_section = output_section(target_display, target_format)

      if same_file?(source_abs, target_abs)
        return failure(operation, "same_file",
                       "Input and output are the same file: #{target_display}",
                       hint: "Choose a different output path.",
                       input: input_section, output: output_section, warnings: warnings,
                       started: started)
      end

      output_error = validate_output(target_display, target_abs)
      if output_error
        return failure(operation, output_error.code, output_error.message,
                       hint: output_error.hint, input: input_section, output: output_section,
                       warnings: warnings, started: started)
      end

      if File.exist?(target_abs) && !force
        return failure(operation, "output_exists",
                       "Output file already exists: #{target_display}",
                       hint: "Pass --force to overwrite it.",
                       input: input_section, output: output_section, warnings: warnings,
                       started: started)
      end

      route_result = @router.route(input_format.id, target_format.id, backend: options["backend"])
      unless route_result.ok?
        error = route_result.error
        return failure(operation, error.code, error.message, hint: error.hint,
                       input: input_section, output: output_section,
                       warnings: warnings + route_result.warnings, started: started)
      end

      warnings.concat(route_result.warnings)
      steps = route_result.steps
      route_hash = steps.map(&:to_h)

      if dry_run
        return Cvt::Result.success(
          operation: "plan",
          input: input_section,
          output: output_section,
          route: route_hash,
          options: display_options,
          timing: { "total_ms" => elapsed_ms(started) },
          warnings: warnings
        )
      end

      convert(source_abs, source_display, target_abs, target_display, target_format,
              steps, input_section, output_section, route_hash, display_options,
              options, warnings, started, debug)
    rescue Interrupt
      failure(operation, "interrupted", "Conversion interrupted",
              hint: "The temporary output was removed; the target was not modified.",
              started: started)
    rescue Cvt::Error => e
      failure(operation, e.code, e.message, hint: e.hint,
              details: e.details, debug: debug, started: started)
    rescue StandardError => e
      failure(operation, "internal_error", "Unexpected internal error",
              hint: "Run with --debug for details, or report the issue.",
              details: e.message, debug: debug, started: started)
    end
    # rubocop:enable Metrics/ParameterLists

    private

    def convert(source_abs, source_display, target_abs, target_display, target_format,
                steps, input_section, output_section, route_hash, display_options,
                options, warnings, started, debug)
      operation = "convert"
      tmpdir = nil
      final_temp = nil
      current_input = source_abs
      created = false

      begin
        tmpdir = Dir.mktmpdir("cvt-steps-")
        final_temp = create_temp_path(File.dirname(target_abs), format_extension(target_format))

        steps.each_with_index do |step, index|
          output = index == steps.size - 1 ? final_temp : intermediate_path(tmpdir, step, index)
          backend = @pool.load(step.backend)
          unless backend
            raise Cvt::Errors.build(
              "backend_unavailable",
              "Backend #{step.backend} is not available",
              hint: "Run cvt --doctor to check engine installation."
            )
          end
          unless backend.respond_to?(:convert)
            raise Cvt::Errors.build(
              "backend_unavailable",
              "Backend #{step.backend} cannot perform conversions",
              hint: "Run cvt --doctor to check engine installation."
            )
          end

          backend.convert(current_input, output,
                          options.merge("from" => step.from, "to" => step.to), warnings)
          unless File.exist?(output)
            raise Cvt::Errors.build(
              "conversion_failed",
              "Backend #{step.backend} did not produce an output file",
              hint: "Run with --debug to inspect the engine output."
            )
          end
          current_input = output
        end

        unless File.exist?(final_temp)
          raise Cvt::Errors.build(
            "conversion_failed",
            "Backend did not produce an output file",
            hint: "Run with --debug to inspect the engine output."
          )
        end

        atomic_replace(final_temp, target_abs)
        created = true

        Cvt::Result.success(
          operation: operation,
          input: input_section.merge("path" => source_display),
          output: output_section.merge("bytes" => File.size(target_abs)),
          route: route_hash,
          options: display_options,
          timing: { "total_ms" => elapsed_ms(started) },
          warnings: warnings
        )
      rescue Interrupt
        raise
      rescue Cvt::Error => e
        failure(operation, e.code, e.message, hint: e.hint,
                details: e.details, debug: debug,
                input: input_section, output: output_section, warnings: warnings,
                started: started, skip_details: false)
      rescue StandardError => e
        failure(operation, "conversion_failed", "Conversion failed: #{e.message}",
                hint: "Check that the input file is valid and the engine is installed.",
                details: e.message, debug: debug,
                input: input_section, output: output_section, warnings: warnings,
                started: started)
      ensure
        if final_temp && !created && File.exist?(final_temp)
          File.delete(final_temp)
        end
        FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir)
      end
    end

    def failure(operation, code, message, hint: "", details: nil, debug: false,
                input: nil, output: nil, warnings: [], started: nil, skip_details: false)
      error_details = nil
      if debug && !skip_details && !details.nil?
        error_details = sanitize_details(details)
      end
      error = Cvt::Errors.build(code, message.to_s.lines.first.to_s.strip, hint: hint,
                                details: error_details)
      document_input = input && input.key?("format") ? input.reject { |key, _| key == "bytes" } : input
      Cvt::Result.failure(
        operation: operation,
        error: error,
        input: document_input,
        output: output,
        warnings: warnings
      )
    rescue StandardError
      Cvt::Result.failure(
        operation: operation,
        code: code,
        message: message,
        hint: hint,
        warnings: warnings
      )
    end

    def validate_source(display, absolute)
      unless File.exist?(absolute)
        return Cvt::Errors.build("input_not_found", "Input file not found: #{display}",
                                 hint: "Check the path and try again.")
      end
      unless File.file?(absolute)
        return Cvt::Errors.build("input_unreadable", "Input is not a regular file: #{display}",
                                 hint: "Provide a single file, not a directory.")
      end
      unless File.readable?(absolute)
        return Cvt::Errors.build("input_unreadable", "Input file is not readable: #{display}",
                                 hint: "Check file permissions and try again.")
      end

      nil
    end

    def resolve_target(source_display, target, to, input_format)
      to_format = nil
      if to && !to.to_s.empty?
        to_format = @registry.format(to)
        unless to_format
          return [Cvt::Errors.build("unknown_format", "Unknown output format: #{to}",
                                    hint: "Run cvt --formats to list supported formats."), nil]
        end
      end

      if target && !target.to_s.empty?
        target_display = target.to_s
        extension_format = @registry.format_for_filename(target_display)
        if to_format
          unless extension_format && extension_format.id == to_format.id
            return [Cvt::Errors.build(
              "usage_error",
              "Target extension does not match --to #{to_format.id}: #{target_display}",
              hint: "Use a target extension that matches --to, or omit --to."
            ), nil]
          end
          return [to_format, target_display]
        end

        unless extension_format
          return [Cvt::Errors.build(
            "unknown_format",
            "Unable to determine the output format from #{target_display}",
            hint: "Pass --to FORMAT to specify the output format."
          ), nil]
        end
        return [extension_format, target_display]
      end

      unless to_format
        return [Cvt::Errors.build(
          "usage_error",
          "TARGET is required unless --to FORMAT is given",
          hint: "Use cvt SOURCE TARGET or cvt SOURCE --to FORMAT."
        ), nil]
      end

      [to_format, auto_target(source_display, input_format, to_format)]
    end

    def auto_target(source_display, input_format, output_format)
      directory = File.dirname(source_display)
      base = File.basename(source_display)
      base = strip_known_extension(base, input_format)
      base = "output" if base.empty?
      name = "#{base}#{format_extension(output_format)}"
      directory == "." ? name : File.join(directory, name)
    end

    def strip_known_extension(basename, format)
      return basename unless format

      suffix = format.extensions.sort_by { |ext| -ext.length }
                      .find { |ext| basename.downcase.end_with?(".#{ext}") }
      suffix ? basename[0...-(suffix.length + 1)] : basename
    end

    def format_extension(format)
      return ".tar.gz" if format.id == "tgz"

      ".#{format.extensions.first}"
    end

    def intermediate_path(tmpdir, step, index)
      format = @registry.format(step.to)
      extension = format ? format_extension(format) : ".#{step.to}"
      File.join(tmpdir, "step#{index}#{extension}")
    end

    def create_temp_path(directory, extension)
      attempts = 0
      loop do
        attempts += 1
        path = File.join(directory, ".cvt-#{Process.pid}-#{SecureRandom.hex(6)}#{extension}")
        return path unless File.exist?(path)
        raise Cvt::Errors.build("output_unwritable", "Unable to create a temporary output file",
                                hint: "Check write permissions for #{directory}.") if attempts > 10
      end
    end

    def atomic_replace(temp_path, target_path)
      if Gem.win_platform? && File.exist?(target_path)
        File.delete(target_path)
      end
      File.rename(temp_path, target_path)
    end

    def validate_output(display, absolute)
      parent = File.dirname(absolute)
      unless File.directory?(parent)
        return Cvt::Errors.build("output_unwritable",
                                 "Output directory does not exist: #{File.dirname(display)}",
                                 hint: "Create the parent directory first.")
      end
      unless File.writable?(parent)
        return Cvt::Errors.build("output_unwritable",
                                 "Output directory is not writable: #{File.dirname(display)}",
                                 hint: "Check write permissions for the output directory.")
      end

      nil
    end

    def same_file?(source_abs, target_abs)
      source_path = comparable_path(source_abs)
      target_path = comparable_path(target_abs)
      return true if source_path == target_path

      if File.exist?(target_abs)
        begin
          return true if File.identical?(source_abs, target_abs)
        rescue StandardError
          nil
        end
      end

      return false unless case_insensitive_platform?

      source_path.downcase == target_path.downcase
    end

    # Windows accepts both separators for the same file; compare one form.
    def comparable_path(path)
      separator = File::ALT_SEPARATOR
      separator ? path.tr(separator, File::SEPARATOR) : path
    end

    def case_insensitive_platform?
      return true if Gem.win_platform?

      host_os = RbConfig::CONFIG["host_os"].to_s
      host_os.match?(/darwin|mac os/)
    end

    def input_section(path, format, bytes: nil)
      Cvt::YAMLOutput.input(path: path, format: format.id, bytes: bytes)
    end

    def output_section(path, format, bytes: nil)
      Cvt::YAMLOutput.output(path: path, format: format.id, bytes: bytes)
    end

    def normalize_hash(value)
      return {} if value.nil?

      value.each_with_object({}) { |(key, child), hash| hash[key.to_s] = child }
    end

    def sanitize_details(details)
      case details
      when Hash
        details.each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = value.to_s == value ? Cvt::Shell.truncate(value) : value.to_s
        end
      when String
        { "stderr" => Cvt::Shell.truncate(details) }
      else
        nil
      end
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1000).round
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
