# frozen_string_literal: true

require "did_you_mean"
require "optparse"
require "rbconfig"

require_relative "doctor"
require_relative "errors"
require_relative "registry"
require_relative "result"
require_relative "runner"
require_relative "version"
require_relative "yaml_output"

module Cvt
  # Single-command CLI: `cvt SOURCE TARGET [options]` or `cvt SOURCE --to FORMAT`.
  # All results are YAML on stdout with the contract from spec R2. stderr stays
  # empty (engine stderr is only exposed through --debug inside error.details).
  class CLI
    CONVERSION_DEFAULTS = {
      "quality" => 85,
      "dpi" => 150,
      "timeout" => 300,
      "encoding" => "UTF-8",
      "root" => "rows",
      "max_size" => 1024 * 1024 * 1024,
      "keep_metadata" => false
    }.freeze
    INFO_FLAGS = %i[version formats backends doctor].freeze

    def self.run(argv, out: $stdout, err: $stderr, registry: Cvt::Registry.default,
                 pool: Cvt::Backends)
      new(out: out, err: err, registry: registry, pool: pool).run(argv)
    end

    def initialize(out: $stdout, err: $stderr, registry: Cvt::Registry.default,
                   pool: Cvt::Backends)
      @out = out
      @err = err
      @registry = registry
      @pool = pool
      @doctor = Cvt::Doctor.new(registry: registry, pool: pool)
      @opts = {
        force: false, dry_run: false, quiet: false, debug: false,
        version: false, formats: false, backends: false, doctor: false,
        available: false, format: nil, category: nil,
        from: nil, to: nil, backend: nil
      }
      @provided = {}
      @display = {}
      @parser = build_parser
    end

    def run(argv)
      prepare_output
      arguments = Array(argv).map(&:to_s)
      if arguments.include?("-h") || arguments.include?("--help")
        @out.puts(@parser)
        return 0
      end
      if arguments.empty?
        @out.puts(@parser)
        return 2
      end

      begin
        positional = @parser.parse!(arguments)
      rescue OptionParser::ParseError => e
        return print_result(usage_result(e.message))
      end

      if (error = info_usage_error(positional))
        return print_result(error)
      end

      return run_version if @opts[:version]
      return run_formats if @opts[:formats]
      return run_backends if @opts[:backends]
      return run_doctor if @opts[:doctor]

      run_conversion(positional)
    rescue Interrupt
      print_result(Cvt::Result.failure(
                     operation: "convert",
                     code: "interrupted",
                     message: "Conversion interrupted",
                     hint: "No output file was written."
                   ))
    rescue StandardError => e
      details = @opts[:debug] ? e.message : nil
      print_result(Cvt::Result.failure(
                     operation: "convert",
                     error: Cvt::Errors.build("internal_error", "Unexpected internal error",
                                              hint: "Run with --debug for details.",
                                              details: details),
                     warnings: []
                   ))
    end

    private

    # YAML is always UTF-8; pin Windows console/pipe streams to UTF-8 so the
    # output does not depend on the active code page. Unix streams are left
    # untouched to keep their bytes unchanged.
    def prepare_output
      return unless Gem.win_platform?

      [@out, @err].each { |io| io.set_encoding(Encoding::UTF_8) if io.respond_to?(:set_encoding) }
    end

    def build_parser
      OptionParser.new do |parser|
        parser.banner = "Usage: cvt SOURCE TARGET [options]\n" \
                        "       cvt SOURCE --to FORMAT [options]"

        parser.separator ""
        parser.separator "Input and output:"
        parser.on("--from FORMAT", "Override input format detection") do |value|
          @opts[:from] = value
        end
        parser.on("-t", "--to FORMAT", "Output format; TARGET becomes optional") do |value|
          @opts[:to] = value
        end
        parser.on("--backend ID", "Restrict every route step to this backend") do |value|
          @opts[:backend] = value
        end

        parser.separator ""
        parser.separator "Conversion options:"
        parser.on("--quality N", Integer, "Lossy image quality, 1-100 (default: 85)") do |value|
          range!("quality", value, 1, 100, "1-100")
          record("quality", value)
        end
        parser.on("--width N", Integer, "Maximum output width in pixels") do |value|
          range!("width", value, 1, nil, "a positive integer")
          record("width", value)
        end
        parser.on("--height N", Integer, "Maximum output height in pixels") do |value|
          range!("height", value, 1, nil, "a positive integer")
          record("height", value)
        end
        parser.on("--dpi N", Integer, "PDF rasterization DPI, 1-600 (default: 150)") do |value|
          range!("dpi", value, 1, 600, "1-600")
          record("dpi", value)
        end
        parser.on("--page N", Integer, "PDF page number, 1-based") do |value|
          range!("page", value, 1, nil, "a positive integer")
          record("page", value)
        end
        parser.on("--sheet NAME|INDEX", "Worksheet name or 1-based index") do |value|
          record("sheet", value)
        end
        parser.on("--delimiter CHAR", "CSV delimiter") do |value|
          unless value.length == 1
            raise OptionParser::InvalidArgument, "--delimiter must be a single character"
          end
          record("delimiter", value)
        end
        parser.on("--bitrate RATE", "Media bitrate, for example 128k or 2M") do |value|
          record("bitrate", value)
        end
        parser.on("--encoding NAME", "Input text encoding (default: UTF-8)") do |value|
          record("encoding", value)
        end
        parser.on("--root KEY", "Root key for table to TOML/XML (default: rows)") do |value|
          record("root", value)
        end
        parser.on("--max-size SIZE", "Native parsing limit, for example 1GiB (0 = unlimited)") do |value|
          record("max_size", parse_size(value), display: value)
        end
        parser.on("--timeout SECONDS", Integer, "External engine timeout (default: 300, 0 = unlimited)") do |value|
          range!("timeout", value, 0, nil, "a non-negative integer")
          record("timeout", value)
        end
        parser.on("--keep-metadata", "Keep image metadata when possible") do
          record("keep_metadata", true)
        end
        parser.on("-f", "--force", "Overwrite an existing output file") do
          @opts[:force] = true
        end
        parser.on("-n", "--dry-run", "Print the route plan without writing files") do
          @opts[:dry_run] = true
        end
        parser.on("-q", "--quiet", "Suppress success YAML output") do
          @opts[:quiet] = true
        end
        parser.on("--debug", "Include truncated engine stderr in error details") do
          @opts[:debug] = true
        end

        parser.separator ""
        parser.separator "Information:"
        parser.on("-l", "--formats", "List registered formats") do
          @opts[:formats] = true
        end
        parser.on("--format ID", "Show details for one format (with --formats)") do |value|
          @opts[:format] = value
        end
        parser.on("--category CAT", "Filter formats by category (with --formats)") do |value|
          @opts[:category] = value
        end
        parser.on("--backends", "List backends") do
          @opts[:backends] = true
        end
        parser.on("--available", "Only available backends (with --backends)") do
          @opts[:available] = true
        end
        parser.on("--doctor", "Report Ruby, platform, and backend availability") do
          @opts[:doctor] = true
        end
        parser.on("--version", "Show version, Ruby, and platform") do
          @opts[:version] = true
        end
        parser.on("-h", "--help", "Show this help") do
          @opts[:help] = true
        end

        parser.separator ""
        parser.separator "Exit codes: 0 success, 2 usage, 3 unsupported, 4 backend missing,"
        parser.separator "            5 unreadable/undetected input, 6 output conflict,"
        parser.separator "            7 conversion failure, 8 timeout, 130 interrupted."
      end
    end

    def record(key, value, display: value)
      @provided[key] = value
      @display[key] = display
    end

    def range!(name, value, minimum, maximum, expected)
      valid = value >= minimum && (maximum.nil? || value <= maximum)
      return if valid

      raise OptionParser::InvalidArgument, "--#{name} must be #{expected}"
    end

    def parse_size(value)
      text = value.to_s.strip
      return 0 if text == "0"

      match = /\A(\d+(?:\.\d+)?)([KMGT]i?B?|B?)\z/i.match(text)
      unless match
        raise OptionParser::InvalidArgument, "invalid --max-size value: #{value}"
      end

      multiplier = case match[2].to_s.downcase
                   when "", "b" then 1
                   when "k", "kb", "kib" then 1024
                   when "m", "mb", "mib" then 1024**2
                   when "g", "gb", "gib" then 1024**3
                   when "t", "tb", "tib" then 1024**4
                   else 1
                   end
      (match[1].to_f * multiplier).to_i
    end

    def info_usage_error(positional = [])
      return usage_result("--format requires --formats") if @opts[:format] && !@opts[:formats]
      return usage_result("--category requires --formats") if @opts[:category] && !@opts[:formats]
      return usage_result("--available requires --backends") if @opts[:available] && !@opts[:backends]
      return nil unless INFO_FLAGS.any? { |flag| @opts[flag] }

      conversion = positional.any? || @provided.any? || @opts[:from] || @opts[:to] ||
                   @opts[:backend] || @opts[:force] || @opts[:dry_run]
      return nil unless conversion

      usage_result("Information options cannot be combined with conversion arguments")
    end

    def run_version
      emit(
        "ok" => true,
        "version" => Cvt::VERSION,
        "operation" => "version",
        "ruby" => RUBY_VERSION,
        "platform" => RUBY_PLATFORM
      )
      0
    end

    def run_formats
      category = nil
      if @opts[:category]
        category = @opts[:category].to_s.downcase
        unless Cvt::Format::CATEGORIES.include?(category)
          suggestion = did_you_mean(category, Cvt::Format::CATEGORIES)
          hint = suggestion ? "Did you mean \"#{suggestion}\"?" : "Choose a category from cvt --formats."
          return print_result(Cvt::Result.failure(
                                operation: "formats", code: "usage_error",
                                message: "Unknown category: #{@opts[:category]}", hint: hint
                              ))
        end
      end

      if @opts[:format]
        format = @registry.format(@opts[:format])
        unless format
          return print_result(unknown_format_result(@opts[:format], operation: "format"))
        end
        emit(
          "ok" => true,
          "version" => Cvt::VERSION,
          "operation" => "format",
          "format" => format_entry(format)
        )
        return 0
      end

      formats = category ? @registry.category(category) : @registry.formats
      entries = formats.map { |format| format_entry(format) }
      emit(
        "ok" => true,
        "version" => Cvt::VERSION,
        "operation" => "formats",
        "count" => entries.size,
        "formats" => entries
      )
      0
    end

    def run_backends
      entries = @registry.backend_ids.sort.map { |id| backend_entry(id) }
      entries = entries.select { |entry| entry["available"] } if @opts[:available]
      emit(
        "ok" => true,
        "version" => Cvt::VERSION,
        "operation" => "backends",
        "count" => entries.size,
        "backends" => entries
      )
      0
    end

    def run_doctor
      emit(@doctor.document)
      0
    end

    def run_conversion(positional)
      source = positional[0]
      target = positional[1]
      if source.nil?
        return print_result(usage_result("SOURCE path is required"))
      end
      if positional.size > 2
        return print_result(usage_result("Only one source and one target file are supported"))
      end

      if @opts[:from]
        format = @registry.format(@opts[:from])
        unless format
          return print_result(unknown_format_result(@opts[:from], operation: "convert"))
        end
        from_id = format.id
      end

      to_id = nil
      if @opts[:to]
        format = @registry.format(@opts[:to])
        unless format
          return print_result(unknown_format_result(@opts[:to], operation: "convert"))
        end
        to_id = format.id
      end

      if target && to_id
        target_format = @registry.format_for_filename(target)
        if target_format.nil? || target_format.id != to_id
          return print_result(usage_result(
                                "Target extension does not match --to #{to_id}: #{target}",
                                hint: "Use a target extension that matches --to, or omit --to."
                              ))
        end
      elsif target.nil? && to_id.nil?
        return print_result(usage_result("TARGET is required unless --to FORMAT is given"))
      elsif target && to_id.nil? && @registry.format_for_filename(target).nil?
        return print_result(unknown_target_result(target))
      end

      if @opts[:backend]
        unless @registry.backend(@opts[:backend])
          suggestion = did_you_mean(@opts[:backend], @registry.backend_ids)
          hint = suggestion ? "Did you mean \"#{suggestion}\"?" : "Run cvt --backends to list backends."
          return print_result(Cvt::Result.failure(
                                operation: "convert", code: "unknown_backend",
                                message: "Unknown backend: #{@opts[:backend]}", hint: hint
                              ))
        end
        backend_id = @opts[:backend].to_s.downcase
      end

      options = CONVERSION_DEFAULTS.merge(@provided)
      options["backend"] = backend_id if backend_id
      runner = Cvt::Runner.new(registry: @registry, pool: @pool)
      print_result(runner.call(
                     source: source,
                     target: target,
                     to: to_id,
                     from: from_id,
                     options: options,
                     display_options: @display,
                     force: @opts[:force],
                     dry_run: @opts[:dry_run],
                     debug: @opts[:debug]
                   ))
    end

    def format_entry(format)
      entry = format.to_h
      read_backends, write_backends = available_backend_index
      reads = read_backends[format.id] || []
      writes = write_backends[format.id] || []
      entry.merge(
        "available" => (format.readable? && !reads.empty?) || (format.writable? && !writes.empty?),
        "backends" => (reads + writes).uniq.sort
      )
    end

    def backend_entry(id)
      info = @doctor.backend_entry(id)
      {
        "id" => id,
        "kind" => info["kind"],
        "available" => info["available"],
        "version" => info["version"],
        "reads" => routes_for(id, :from),
        "writes" => routes_for(id, :to),
        "hint" => info["hint"]
      }
    end

    def routes_for(backend_id, endpoint)
      formats = @registry.routes.select { |route| route.backend == backend_id }
                           .map { |route| endpoint == :from ? route.from : route.to }
      formats.uniq.sort
    end

    def available_backend_index
      @available_backend_index ||= begin
        reads = Hash.new { |hash, key| hash[key] = [] }
        writes = Hash.new { |hash, key| hash[key] = [] }
        @registry.routes.each do |route|
          available = @registry.route_available?(route, pool: @pool)
          next unless available

          reads[route.from] << route.backend
          writes[route.to] << route.backend
        end
        reads.each_value(&:uniq!)
        writes.each_value(&:uniq!)
        [reads, writes]
      end
    end

    def unknown_format_result(value, operation:)
      suggestion = suggest_format(value)
      hint = if suggestion
               "Did you mean \"#{suggestion}\"?"
             else
               "Run cvt --formats to list supported formats."
             end
      Cvt::Result.failure(operation: operation, code: "unknown_format",
                          message: "Unknown format: #{value}", hint: hint)
    end

    def unknown_target_result(target)
      extension = File.extname(target.to_s).delete_prefix(".")
      suggestion = suggest_format(extension)
      hint = if suggestion
               "Did you mean \"#{suggestion}\"? Or pass --to FORMAT."
             else
               "Pass --to FORMAT to specify the output format."
             end
      Cvt::Result.failure(
        operation: "convert",
        code: "unknown_format",
        message: "Unable to determine the output format from #{target}",
        hint: hint
      )
    end

    def suggest_format(value)
      names = @registry.formats.flat_map { |format| [format.id] + format.aliases + format.extensions }
      match = did_you_mean(value.to_s.downcase, names)
      match && @registry.format(match)&.id
    end

    def did_you_mean(value, dictionary)
      DidYouMean::SpellChecker.new(dictionary: dictionary.uniq).correct(value.to_s).first
    rescue StandardError
      nil
    end

    def usage_result(message, hint: "Run cvt --help for usage.")
      Cvt::Result.failure(operation: "convert", code: "usage_error",
                          message: message, hint: hint)
    end

    def print_result(result)
      @out.write(result.to_yaml) unless result.ok? && @opts[:quiet]
      result.exit_code
    end

    def emit(document)
      @out.write(Cvt::YAMLOutput.dump(document)) unless @opts[:quiet]
    end
  end
end
