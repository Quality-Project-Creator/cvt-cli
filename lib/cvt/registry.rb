# frozen_string_literal: true

require "psych"
require_relative "format"
require_relative "route"
require_relative "backend"

module Cvt
  # Loads data/formats.yml and data/routes.yml once and exposes deterministic
  # lookups. Registry data is the single source of truth: nothing here hard
  # codes conversions. Availability filtering is optional so the registry can
  # be inspected on a machine with no engines installed.
  class Registry
    class InvalidRegistry < StandardError; end

    EXPECTED_FORMAT_COUNT = 56
    EXPECTED_BACKEND_COUNT = 13
    CATEGORY_ORDER = Format::CATEGORIES
    DEFAULT_FORMATS_PATH = File.expand_path("../../data/formats.yml", __dir__)
    DEFAULT_ROUTES_PATH = File.expand_path("../../data/routes.yml", __dir__)
    FORMAT_ID_PATTERN = /\A[a-z][a-z0-9_]*\z/
    EXTENSION_PATTERN = /\A[a-z0-9][a-z0-9._+-]*\z/

    BackendInfo = Struct.new(:id, :kind)

    attr_reader :formats, :backends, :routes, :groups

    def self.default
      @default ||= load
    end

    def self.load(formats_path: DEFAULT_FORMATS_PATH, routes_path: DEFAULT_ROUTES_PATH)
      new(formats_path: formats_path, routes_path: routes_path)
    end

    def self.reset_default!
      @default = nil
    end

    def initialize(formats_path: DEFAULT_FORMATS_PATH, routes_path: DEFAULT_ROUTES_PATH)
      formats_data = read_yaml(formats_path)
      routes_data = read_yaml(routes_path)

      build_formats(formats_data)
      build_groups(routes_data.fetch("groups", {}))
      build_backends(routes_data.fetch("backends", {}))
      build_routes(routes_data.fetch("routes", []))
      validate!
    end

    # Canonical ID, alias, or extension (leading dots and case are ignored).
    def format(name)
      @lookup[normalize_name(name)]
    end
    alias resolve format

    def format_ids
      @formats.map(&:id)
    end

    def format_for_extension(extension)
      @lookup[normalize_name(extension)]
    end

    # Resolves the longest known suffix, so "backup.tar.gz" maps to tgz and
    # "photo.JPEG" maps to jpg.
    def format_for_filename(path)
      basename = File.basename(path.to_s).downcase
      return nil if basename.empty?

      suffix = @suffix_keys.find { |key| basename.end_with?(".#{key}") }
      suffix && @lookup[suffix]
    end

    def category(name)
      key = name.to_s.downcase
      return nil unless CATEGORY_ORDER.include?(key)

      @formats.select { |format| format.category == key }
    end

    def readable_formats
      @formats.select(&:readable?)
    end

    def writable_formats
      @formats.select(&:writable?)
    end

    def formats_for_mime(mime)
      key = mime.to_s.downcase.split(";").first.to_s.strip
      @mime_index.fetch(key, []).map { |id| @formats_by_id[id] }
    end

    def format_for_mime(mime)
      formats_for_mime(mime).first
    end

    def backend(id)
      @backends[id.to_s.downcase]
    end

    def backend_ids
      @backends.keys
    end

    def group(name)
      @groups[name.to_s]
    end

    def routes_from(from)
      format = format(from)
      return [] unless format

      @routes_by_from.fetch(format.id, [])
    end

    def routes_to(to)
      format = format(to)
      return [] unless format

      @routes_by_to.fetch(format.id, [])
    end

    def direct_routes(from, to)
      from_format = format(from)
      to_format = format(to)
      return [] unless from_format && to_format

      @routes.select { |route| route.from == from_format.id && route.to == to_format.id }
    end

    # All routes, optionally narrowed by endpoint and filtered by the pool's
    # current availability. A pool must respond to
    # available_for?(backend_id, from, to, requirements).
    def available_routes(from: nil, to: nil, pool: Cvt::Backends)
      candidates = @routes
      if from
        from_format = format(from)
        candidates = from_format ? candidates.select { |route| route.from == from_format.id } : []
      end
      if to
        to_format = format(to)
        candidates = to_format ? candidates.select { |route| route.to == to_format.id } : []
      end
      candidates.select { |route| route_available?(route, pool: pool) }
    end

    def route_available?(route, pool: Cvt::Backends)
      !!pool.available_for?(route.backend, route.from, route.to, route.requirements)
    rescue StandardError
      false
    end

    def validate!
      if @formats.size != EXPECTED_FORMAT_COUNT
        raise InvalidRegistry,
              "expected #{EXPECTED_FORMAT_COUNT} formats, found #{@formats.size}"
      end
      if @backends.size != EXPECTED_BACKEND_COUNT
        raise InvalidRegistry,
              "expected #{EXPECTED_BACKEND_COUNT} backends, found #{@backends.size}"
      end

      @formats.each do |format|
        if format.readable? && routes_from(format.id).empty?
          raise InvalidRegistry, "format #{format.id} is readable but has no route from it"
        end
        if format.writable? && routes_to(format.id).empty?
          raise InvalidRegistry, "format #{format.id} is writable but has no route to it"
        end
      end

      self
    end

    private

    def read_yaml(path)
      data = Psych.safe_load(File.read(path, encoding: "UTF-8"), permitted_classes: [],
                             aliases: false)
      raise InvalidRegistry, "registry file is empty: #{path}" if data.nil?
      raise InvalidRegistry, "registry file must contain a mapping: #{path}" unless data.is_a?(Hash)

      data
    rescue Errno::ENOENT
      raise InvalidRegistry, "registry file not found: #{path}"
    end

    def build_formats(data)
      raw_formats = data.fetch("formats")
      unless raw_formats.is_a?(Hash)
        raise InvalidRegistry, "formats must be a mapping"
      end

      @formats_by_id = {}
      @lookup = {}
      @aliases = {}
      @mime_index = Hash.new { |hash, key| hash[key] = [] }

      raw_formats.each do |id, attributes|
        format = build_format(id, attributes)
        if @formats_by_id.key?(format.id)
          raise InvalidRegistry, "duplicate format id: #{format.id}"
        end

        @formats_by_id[format.id] = format
        register_name(format.id, format)
        format.extensions.each { |extension| register_name(extension, format) }
        format.aliases.each { |name| register_alias(name, format) }
        @mime_index[format.mime] << format.id
      end

      @formats = @formats_by_id.values.sort_by do |format|
        [CATEGORY_ORDER.index(format.category) || CATEGORY_ORDER.size, format.id]
      end.freeze
      @suffix_keys = @lookup.keys.sort_by { |key| -key.length }.freeze
    end

    def build_format(id, attributes)
      unless attributes.is_a?(Hash)
        raise InvalidRegistry, "format #{id} must be a mapping"
      end

      key = id.to_s
      unless FORMAT_ID_PATTERN.match?(key)
        raise InvalidRegistry, "invalid format id: #{id.inspect}"
      end

      category = attributes.fetch("category").to_s
      unless CATEGORY_ORDER.include?(category)
        raise InvalidRegistry, "format #{key} has unknown category: #{category}"
      end

      read = attributes.fetch("read")
      write = attributes.fetch("write")
      unless [true, false].include?(read) && [true, false].include?(write)
        raise InvalidRegistry, "format #{key} read/write must be booleans"
      end

      extensions = Array(attributes.fetch("extensions")).map do |extension|
        value = extension.to_s.downcase.delete_prefix(".")
        unless EXTENSION_PATTERN.match?(value)
          raise InvalidRegistry, "format #{key} has invalid extension: #{extension.inspect}"
        end
        value
      end
      raise InvalidRegistry, "format #{key} has no extensions" if extensions.empty?

      Format.new(
        id: key,
        category: category,
        extensions: extensions,
        mime: attributes.fetch("mime"),
        read: read,
        write: write,
        aliases: Array(attributes.fetch("aliases", []))
      )
    end

    def register_name(name, format)
      key = normalize_name(name)
      raise InvalidRegistry, "empty format name in #{format.id}" if key.empty?

      existing = @lookup[key]
      if existing && existing.id != format.id
        raise InvalidRegistry, "ambiguous format name #{key.inspect}: #{existing.id} and #{format.id}"
      end

      @lookup[key] = format
    end

    def register_alias(name, format)
      key = normalize_name(name)
      raise InvalidRegistry, "format #{format.id} has an empty alias" if key.empty?

      if @formats_by_id.key?(key)
        raise InvalidRegistry, "alias #{key.inspect} in #{format.id} is a canonical format id"
      end

      existing = @aliases[key]
      if existing && existing != format.id
        raise InvalidRegistry, "alias #{key.inspect} is declared by #{existing} and #{format.id}"
      end

      @aliases[key] = format.id
      register_name(key, format)
    end

    def build_groups(raw_groups)
      unless raw_groups.is_a?(Hash)
        raise InvalidRegistry, "groups must be a mapping"
      end

      @groups = {}
      raw_groups.each do |name, members|
        key = name.to_s
        if @formats_by_id.key?(key) || @aliases.key?(key)
          raise InvalidRegistry, "group name #{key.inspect} conflicts with a format"
        end
        unless members.is_a?(Array) && !members.empty?
          raise InvalidRegistry, "group #{key} must be a non-empty array"
        end

        @groups[key] = members.map { |member| format_id!(member, "group #{key}") }.freeze
      end
      @groups.freeze
    end

    def build_backends(raw_backends)
      unless raw_backends.is_a?(Hash)
        raise InvalidRegistry, "backends must be a mapping"
      end

      @backends = {}
      raw_backends.each do |id, attributes|
        key = id.to_s
        unless FORMAT_ID_PATTERN.match?(key)
          raise InvalidRegistry, "invalid backend id: #{id.inspect}"
        end
        if @backends.key?(key)
          raise InvalidRegistry, "duplicate backend id: #{key}"
        end

        kind = attributes.is_a?(Hash) ? attributes.fetch("kind", "unknown") : attributes
        @backends[key] = BackendInfo.new(key, kind.to_s).freeze
      end
      @backends.freeze
    end

    def build_routes(raw_routes)
      unless raw_routes.is_a?(Array)
        raise InvalidRegistry, "routes must be an array"
      end

      routes = []
      seen = {}
      raw_routes.each_with_index do |entry, index|
        unless entry.is_a?(Hash)
          raise InvalidRegistry, "route ##{index} must be a mapping"
        end

        backend = entry.fetch("backend").to_s
        unless @backends.key?(backend)
          raise InvalidRegistry, "route ##{index} uses unknown backend: #{backend}"
        end

        priority = entry.fetch("priority")
        unless priority.is_a?(Integer)
          raise InvalidRegistry, "route ##{index} priority must be an Integer"
        end
        lossy = entry.fetch("lossy")
        unless [true, false].include?(lossy)
          raise InvalidRegistry, "route ##{index} lossy must be a boolean"
        end
        requirements = entry.fetch("requirements", [])
        unless requirements.is_a?(Array) && requirements.all? { |name| name.is_a?(String) }
          raise InvalidRegistry, "route ##{index} requirements must be an array of strings"
        end

        froms = expand_endpoint(entry.fetch("from"), index)
        tos = expand_endpoint(entry.fetch("to"), index)
        froms.product(tos).each do |from, to|
          next if from == to

          key = [backend, from, to]
          if seen[key]
            raise InvalidRegistry, "duplicate route #{backend}: #{from} -> #{to}"
          end
          seen[key] = true
          routes << Route.new(backend: backend, from: from, to: to, priority: priority,
                              lossy: lossy, requirements: requirements)
        end
      end

      @routes = routes.sort_by(&:sort_key).freeze
      @routes_by_from = @routes.group_by(&:from)
      @routes_by_to = @routes.group_by(&:to)
    end

    def expand_endpoint(token, index)
      Array(token).flat_map do |name|
        key = name.to_s
        if @groups.key?(key)
          @groups[key]
        else
          [format_id!(key, "route ##{index}")]
        end
      end
    end

    def format_id!(name, context)
      format = format(name)
      raise InvalidRegistry, "#{context} references unknown format: #{name.inspect}" unless format

      format.id
    end

    def normalize_name(name)
      name.to_s.downcase.delete_prefix(".")
    end
  end
end
