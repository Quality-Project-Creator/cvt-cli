# frozen_string_literal: true

module Cvt
  # Base class for every backend adapter. This interface is frozen after
  # Task 1; adapters must implement the four methods below and must never
  # pretend a conversion works when the engine is missing.
  #
  # Adapter file convention: lib/cvt/backends/<id>.rb defines a subclass of
  # Cvt::Backend and declares `id "<id>"`. The file is only loaded on demand.
  #
  # Contract:
  # - id: stable lowercase identifier matching data/routes.yml
  # - kind: "native", "gem", "cli", or a documented combination
  # - priority: lower numbers are preferred when routing ties
  # - requirements: static backend-level external tools (routes carry their own)
  # - available?: true only when the engine can actually run
  # - available_for?(from, to, requirements): route-level availability
  # - version: engine version String or nil
  # - convert(input, output, options, warnings): input/output are absolute
  #   path Strings; options has String keys; warnings receives
  #   {"code" => ..., "message" => ...} Hashes; raise Cvt::Error on failure.
  class Backend
    class << self
      def id(value = nil)
        if value
          @id = value.to_s
          Backend.register(self)
        else
          @id
        end
      end

      def kind(value = nil)
        value ? (@kind = value.to_s) : @kind
      end

      def priority(value = nil)
        value ? (@priority = Integer(value)) : @priority
      end

      def requirements(value = nil)
        if value
          @requirements = Array(value).map { |name| name.to_s.freeze }.freeze
        else
          @requirements || []
        end
      end

      def register(klass)
        key = klass.id
        return if key.nil? || key.empty?

        existing = implementations[key]
        if existing && existing != klass
          raise ArgumentError, "duplicate backend id: #{key}"
        end

        implementations[key] = klass
      end

      def implementation(id)
        implementations[id.to_s]
      end

      def implementations
        @implementations ||= {}
      end
    end

    def id
      self.class.id
    end

    def kind
      self.class.kind
    end

    def priority
      self.class.priority || 0
    end

    def requirements
      self.class.requirements
    end

    def available?
      false
    end

    def available_for?(_from, _to, _requirements = [])
      available?
    end

    def version
      nil
    end

    def convert(_input, _output, _options = {}, _warnings = [])
      raise NotImplementedError, "#{self.class} must implement #convert"
    end
  end

  # Lazy backend aggregator. Missing adapter files, missing gems, and errors
  # raised while loading or probing a backend all degrade to "unavailable"
  # instead of crashing the process.
  #
  # ponytail: one process-wide cache without locks; the CLI converts serially.
  module Backends
    ID_PATTERN = /\A[a-z][a-z0-9_]*\z/
    @cache = {}
    @errors = {}

    class << self
      # Returns the backend instance or nil. Never raises for a missing or
      # broken adapter; inspect load_error(id) for the reason.
      def load(id)
        key = normalize(id)
        return nil unless key
        return @cache[key] if @cache.key?(key)

        @cache[key] = load_adapter(key)
      end

      def available?(id)
        backend = load(id)
        backend ? !!backend.available? : false
      rescue StandardError => e
        record_error(id, e)
        false
      end

      def available_for?(id, from, to, requirements = [])
        backend = load(id)
        return false unless backend

        !!backend.available_for?(from.to_s, to.to_s, Array(requirements))
      rescue StandardError => e
        record_error(id, e)
        false
      end

      def available(ids)
        Array(ids).map(&:to_s).select { |id| available?(id) }
      end

      def load_error(id)
        @errors[normalize(id)]
      end

      def reset!
        @cache.clear
        @errors.clear
        self
      end

      private

      def normalize(id)
        key = id.to_s.downcase
        ID_PATTERN.match?(key) ? key : nil
      end

      def load_adapter(key)
        require_relative "backends/#{key}"
        klass = Backend.implementation(key)
        unless klass
          @errors[key] = "lib/cvt/backends/#{key}.rb did not register backend #{key.inspect}"
          return nil
        end

        klass.new
      rescue LoadError => e
        @errors[key] = "backend #{key} is unavailable: #{e.message}"
        nil
      rescue StandardError => e
        @errors[key] = "backend #{key} failed to load: #{e.message}"
        nil
      end

      def record_error(id, error)
        key = normalize(id)
        @errors[key] = "backend #{key} availability check failed: #{error.message}" if key
      end
    end
  end
end
