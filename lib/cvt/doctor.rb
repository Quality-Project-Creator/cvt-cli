# frozen_string_literal: true

require_relative "bin"
require_relative "registry"
require_relative "version"
require_relative "yaml_output"

module Cvt
  # Environment report used by `cvt --doctor` and `cvt --backends`. Every
  # backend entry carries the executable path of its CLI engine (null for pure
  # gem/native backends), the engine version, availability, and a
  # platform-specific installation hint when unavailable. Only paths and
  # versions are reported; the full environment is never dumped.
  class Doctor
    Tool = Struct.new(:names, :env_var, keyword_init: true)
    Engine = Struct.new(:tools, :hint_tool, :env_hint, :version_args, :version_pattern,
                        :fallback_paths, keyword_init: true)

    ENGINES = {
      "ffmpeg" => Engine.new(
        tools: [Tool.new(names: %w[ffmpeg], env_var: "CVT_BIN_FFMPEG"),
                Tool.new(names: %w[ffprobe], env_var: "CVT_BIN_FFPROBE")],
        hint_tool: "ffmpeg",
        env_hint: "CVT_BIN_FFMPEG and CVT_BIN_FFPROBE",
        version_args: ["-version"],
        version_pattern: /ffmpeg version (\S+)/
      ),
      "rsvg" => Engine.new(
        tools: [Tool.new(names: %w[rsvg-convert], env_var: "CVT_BIN_RSVG_CONVERT")],
        hint_tool: "librsvg",
        env_hint: "CVT_BIN_RSVG_CONVERT",
        version_args: ["--version"],
        version_pattern: /rsvg-convert version ([0-9][0-9.]*)/
      ),
      "pdf" => Engine.new(
        tools: [Tool.new(names: %w[pdftoppm], env_var: "CVT_BIN_PDFTOPPM"),
                Tool.new(names: %w[pdftotext], env_var: "CVT_BIN_PDFTOTEXT")],
        hint_tool: "poppler",
        env_hint: "CVT_BIN_PDFTOPPM and CVT_BIN_PDFTOTEXT",
        version_args: ["-v"],
        version_pattern: /pdftoppm version ([0-9][0-9.]*)/
      ),
      "pandoc" => Engine.new(
        tools: [Tool.new(names: %w[pandoc], env_var: "CVT_BIN_PANDOC")],
        hint_tool: "pandoc",
        env_hint: "CVT_BIN_PANDOC",
        version_args: ["--version"],
        version_pattern: /pandoc\s+([0-9][0-9.]*)/
      ),
      "calibre" => Engine.new(
        tools: [Tool.new(names: %w[ebook-convert], env_var: "CVT_BIN_EBOOK_CONVERT")],
        hint_tool: "calibre",
        env_hint: "CVT_BIN_EBOOK_CONVERT",
        version_args: ["--version"],
        version_pattern: /([0-9]+\.[0-9]+\.[0-9]+)/
      ),
      "native_archive" => Engine.new(
        tools: [Tool.new(names: %w[xz], env_var: "CVT_BIN_XZ"),
                Tool.new(names: %w[bzip2], env_var: "CVT_BIN_BZIP2"),
                Tool.new(names: %w[7z 7za 7zz], env_var: "CVT_BIN_SEVENZIP")],
        hint_tool: "xz",
        env_hint: "CVT_BIN_XZ, CVT_BIN_BZIP2, and CVT_BIN_SEVENZIP"
      )
    }.freeze

    GEM_HINTS = {
      "native_data" => "Install the Ruby gems with \"gem install nokogiri toml-rb\" " \
                       "and run cvt --doctor again.",
      "native_text" => "Install the Ruby gems with \"gem install kramdown nokogiri\" " \
                       "and run cvt --doctor again.",
      "native_archive" => "Install the Ruby gem with \"gem install rubyzip\" " \
                          "and run cvt --doctor again.",
      "native_subtitle" => "Install the Ruby gem with \"gem install srt\" " \
                           "and run cvt --doctor again.",
      "spreadsheet" => "Install the Ruby gems with \"gem install roo caxlsx\" " \
                       "and run cvt --doctor again."
    }.freeze

    # Ruby-side dependencies reported separately from CLI engines.
    NATIVE_DEPENDENCIES = %w[
      marcel rubyzip kramdown nokogiri toml-rb srt roo caxlsx pdf-reader prawn ruby-vips mini_magick
    ].freeze

    def initialize(registry: Cvt::Registry.default, pool: Cvt::Backends)
      @registry = registry
      @pool = pool
    end

    def document
      backends = @registry.backend_ids.sort.map { |id| backend_entry(id) }
      {
        "ok" => true,
        "version" => Cvt::VERSION,
        "operation" => "doctor",
        "ruby" => RUBY_VERSION,
        "platform" => RUBY_PLATFORM,
        "registry" => {
          "formats" => @registry.formats.size,
          "backends" => @registry.backends.size
        },
        "native_dependencies" => native_dependencies,
        "available_formats" => available_formats,
        "backends" => backends,
        "warnings" => []
      }
    end

    def backend_entry(id)
      info = @registry.backend(id)
      available = available?(id)
      {
        "id" => id,
        "kind" => info&.kind.to_s,
        "available" => available,
        "version" => engine_version(id) || backend_version(id),
        "path" => engine_path(id),
        "hint" => available ? "" : hint_for(id)
      }
    end

    def available?(id)
      !!@pool.available?(id)
    rescue StandardError
      false
    end

    private

    def backend_version(id)
      @pool.load(id)&.version
    rescue StandardError
      nil
    end

    def engine_for(id)
      case id
      when "imagemagick" then imagemagick_engine
      when "libreoffice" then libreoffice_engine
      else ENGINES[id]
      end
    end

    def imagemagick_engine
      names = Cvt::Bin.platform == "windows" ? %w[magick] : %w[magick convert]
      Engine.new(
        tools: [Tool.new(names: names, env_var: "CVT_BIN_MAGICK")],
        hint_tool: "imagemagick",
        env_hint: "CVT_BIN_MAGICK",
        version_args: ["-version"],
        version_pattern: /ImageMagick ([0-9][0-9.-]*)/
      )
    end

    def libreoffice_engine
      Engine.new(
        tools: [Tool.new(names: %w[soffice libreoffice], env_var: "CVT_BIN_SOFFICE")],
        hint_tool: "libreoffice",
        env_hint: "CVT_BIN_SOFFICE",
        version_args: ["--version"],
        version_pattern: /LibreOffice\s+([0-9][0-9.]*)/,
        fallback_paths: libreoffice_paths
      )
    end

    def libreoffice_paths
      case Cvt::Bin.platform
      when "macos"
        [
          "/Applications/LibreOffice.app/Contents/MacOS/soffice",
          File.expand_path("~/Applications/LibreOffice.app/Contents/MacOS/soffice")
        ]
      when "windows"
        [
          'C:\Program Files\LibreOffice\program\soffice.exe',
          'C:\Program Files (x86)\LibreOffice\program\soffice.exe'
        ]
      else
        []
      end
    end

    def engine_path(id)
      return Cvt::Bin.imagemagick if id == "imagemagick"

      engine = engine_for(id)
      return nil unless engine

      engine.tools.each do |tool|
        path = tool_path(engine, tool)
        return path if path
      end
      nil
    end

    def tool_path(engine, tool)
      path = Cvt::Bin.find(tool.names, env_var: tool.env_var)
      return path if path

      Array(engine.fallback_paths).find { |candidate| executable?(candidate) }
    rescue StandardError
      nil
    end

    def executable?(path)
      File.file?(path) && File.executable?(path)
    rescue StandardError
      false
    end

    def engine_version(id)
      engine = engine_for(id)
      return nil if engine.nil? || engine.version_args.nil?

      path = engine_path(id)
      return nil unless path

      Cvt::Bin.version(path, engine.version_args, engine.version_pattern)
    rescue StandardError
      nil
    end

    def hint_for(id)
      engine = engine_for(id)
      return gem_hint(id) if engine.nil? || id == "native_archive"

      parts = [Cvt::Bin.hint(engine.hint_tool)]
      parts << "The mini_magick gem is also required." if id == "imagemagick"
      parts << "Alternatively install the pdf-reader and prawn Ruby gems." if id == "pdf"
      parts << "Set #{engine.env_hint} to override the binary paths."
      parts.join(" ")
    end

    def gem_hint(id)
      case id
      when "vips"
        "#{Cvt::Bin.hint('libvips')} Then install the ruby-vips gem."
      else
        GEM_HINTS[id] || "Install the Ruby gems required by #{id} with bundle install " \
                         "and run cvt --doctor again."
      end
    end

    def native_dependencies
      NATIVE_DEPENDENCIES.map do |name|
        spec = begin
          Gem::Specification.find_by_name(name)
        rescue StandardError
          nil
        end
        {
          "name" => name,
          "available" => !spec.nil?,
          "version" => spec&.version&.to_s
        }
      end
    end

    def available_formats
      ids = []
      @registry.routes.each do |route|
        available = begin
          @pool.available_for?(route.backend, route.from, route.to, route.requirements)
        rescue StandardError
          false
        end
        next unless available

        ids << route.from
        ids << route.to
      end
      ids.uniq.size
    end
  end
end
