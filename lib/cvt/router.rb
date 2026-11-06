# frozen_string_literal: true

require_relative "errors"
require_relative "registry"

module Cvt
  # Resolves a deterministic conversion path through the declarative route
  # registry. Direct routes are preferred; otherwise a single intermediate
  # format is used (at most two hops). The intermediate format may not be `txt`
  # so PDF/Office files are never silently degraded to plain text.
  #
  # Backend availability is injected through `pool`, which must respond to
  # `available_for?(backend_id, from, to, requirements)`. The default is
  # Cvt::Backends; tests pass a fake pool.
  class Router
    Path = Struct.new(:steps, keyword_init: true) do
      def size
        steps.size
      end

      def backends
        steps.map(&:backend)
      end

      def sort_key
        total_priority = steps.sum(&:priority)
        lossy_count = steps.count(&:lossy?)
        [steps.size, total_priority, lossy_count] + (# lexical tie-breaker
          steps.flat_map { |step| [step.backend, step.from, step.to] })
      end
    end

    Result = Struct.new(:steps, :warnings, :error, keyword_init: true) do
      def ok?
        error.nil?
      end

      def exit_code
        ok? ? 0 : error.exit_code
      end
    end

    FORBIDDEN_INTERMEDIATE = "txt"

    def initialize(registry: Cvt::Registry.default, pool: Cvt::Backends)
      @registry = registry
      @pool = pool
    end

    # Returns a Result with Route steps on success, or a Cvt::Error describing
    # why no usable path exists. `backend` restricts every step in the route.
    def route(from, to, backend: nil)
      from_format = @registry.format(from)
      to_format = @registry.format(to)
      return failure(unknown_format_error(from, "input")) unless from_format
      return failure(unknown_format_error(to, "output")) unless to_format

      from_id = from_format.id
      to_id = to_format.id
      return failure(same_format_error(from_id)) if from_id == to_id

      candidates = candidate_paths(from_id, to_id, backend)
      available = candidates.select { |path| path_available?(path) }

      if available.any?
        return build_success(available.min_by(&:sort_key))
      end

      if candidates.any?
        return failure(unavailable_error(from_id, to_id, candidates, backend))
      end

      unrestricted = backend ? candidate_paths(from_id, to_id, nil) : []
      if backend && unrestricted.any?
        return failure(restricted_unavailable_error(from_id, to_id, backend))
      end

      failure(unsupported_error(from_id, to_id))
    end

    private

    def failure(error)
      Result.new(steps: [], warnings: [], error: error)
    end

    def build_success(path)
      warnings = []
      if path.size > 1
        warnings << {
          "code" => "multi_step_route",
          "message" => "Conversion uses #{path.size} steps: #{steps_text(path)}."
        }
      end
      if path.steps.any?(&:lossy?)
        lossy = path.steps.select(&:lossy?)
        warnings << {
          "code" => "lossy_conversion",
          "message" => "Conversion includes lossy step(s): #{steps_text(Path.new(steps: lossy))}."
        }
      end

      Result.new(steps: path.steps, warnings: warnings, error: nil)
    end

    def steps_text(path)
      path.steps.map { |step| "#{step.backend}:#{step.from}->#{step.to}" }.join(", ")
    end

    def candidate_paths(from_id, to_id, backend)
      direct = @registry.direct_routes(from_id, to_id).map { |route| Path.new(steps: [route]) }

      two_hop = @registry.routes_from(from_id).flat_map do |first|
        next [] if first.to == FORBIDDEN_INTERMEDIATE
        next [] if first.to == to_id

        @registry.direct_routes(first.to, to_id).map do |second|
          Path.new(steps: [first, second])
        end
      end

      (direct + two_hop).select { |path| allowed_backend?(path, backend) }
    end

    def allowed_backend?(path, backend)
      return true if backend.nil?

      path.steps.all? { |step| step.backend == backend }
    end

    def path_available?(path)
      path.steps.all? do |step|
        !!@pool.available_for?(step.backend, step.from, step.to, step.requirements)
      rescue StandardError
        false
      end
    end

    def unknown_format_error(value, role)
      Cvt::Errors.build(
        "unknown_format",
        "Unknown #{role} format: #{value}",
        hint: "Run cvt --formats to list supported formats."
      )
    end

    def same_format_error(id)
      Cvt::Errors.build(
        "unsupported_conversion",
        "Input and output formats are both #{id}",
        hint: "Choose a different output format; same-format conversion is not supported."
      )
    end

    def unsupported_error(from_id, to_id)
      hint = if from_id == "pdf"
               "PDF files cannot be converted to #{to_id}. Convert to txt first with " \
                 "--to txt, or to png/jpg for images."
             else
               "Run cvt --formats to see supported formats and conversion paths."
             end
      Cvt::Errors.build(
        "unsupported_conversion",
        "No conversion route from #{from_id} to #{to_id}",
        hint: hint
      )
    end

    def unavailable_error(from_id, to_id, candidates, backend)
      missing = candidates.flat_map(&:backends).uniq.sort
      hint = "Install the missing engine(s) or run cvt --doctor for details. " \
             "Missing backend(s): #{missing.join(', ')}."
      hint += " Retry without --backend or choose another backend." if backend
      Cvt::Errors.build(
        "backend_unavailable",
        "No available backend can convert #{from_id} to #{to_id}",
        hint: hint
      )
    end

    def restricted_unavailable_error(from_id, to_id, backend)
      Cvt::Errors.build(
        "backend_unavailable",
        "Backend #{backend} cannot convert #{from_id} to #{to_id}",
        hint: "Retry without --backend, or choose a backend listed by cvt --backends."
      )
    end
  end
end
