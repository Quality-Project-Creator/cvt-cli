# frozen_string_literal: true

require "rbconfig"

require_relative "shell"

module Cvt
  # Cross-platform executable lookup and engine metadata helpers. All probing
  # is done with Ruby file APIs; no `which`, `where`, or shell interpolation.
  module Bin
    WINDOWS_SUFFIXES = %w[.com .exe .bat .cmd].freeze

    TOOL_ALIASES = {
      "magick" => "imagemagick",
      "convert" => "imagemagick",
      "imagemagick" => "imagemagick",
      "ffmpeg" => "ffmpeg",
      "pandoc" => "pandoc",
      "soffice" => "libreoffice",
      "libreoffice" => "libreoffice",
      "ebook-convert" => "calibre",
      "calibre" => "calibre",
      "pdftoppm" => "poppler",
      "pdftotext" => "poppler",
      "poppler" => "poppler",
      "rsvg-convert" => "librsvg",
      "rsvg" => "librsvg",
      "librsvg" => "librsvg",
      "xz" => "xz",
      "bzip2" => "bzip2",
      "7z" => "7zip",
      "7za" => "7zip",
      "7zip" => "7zip",
      "vips" => "libvips",
      "libvips" => "libvips"
    }.freeze

    HINTS = {
      "imagemagick" => {
        "windows" => "Install ImageMagick: winget install ImageMagick.ImageMagick or choco install imagemagick. " \
                     "Use magick.exe; Windows convert.exe is a filesystem tool.",
        "macos" => "Install ImageMagick: brew install imagemagick.",
        "linux" => "Install ImageMagick: apt install imagemagick (or use your distro package manager)."
      },
      "ffmpeg" => {
        "windows" => "Install FFmpeg: winget install Gyan.FFmpeg or choco install ffmpeg.",
        "macos" => "Install FFmpeg: brew install ffmpeg.",
        "linux" => "Install FFmpeg: apt install ffmpeg (or use your distro package manager)."
      },
      "pandoc" => {
        "windows" => "Install Pandoc: winget install JohnMacFarlane.Pandoc or choco install pandoc.",
        "macos" => "Install Pandoc: brew install pandoc.",
        "linux" => "Install Pandoc: apt install pandoc (or use your distro package manager)."
      },
      "libreoffice" => {
        "windows" => "Install LibreOffice: winget install TheDocumentFoundation.LibreOffice or choco install libreoffice.",
        "macos" => "Install LibreOffice: brew install --cask libreoffice.",
        "linux" => "Install LibreOffice: apt install libreoffice (or use your distro package manager)."
      },
      "calibre" => {
        "windows" => "Install Calibre: winget install calibre.calibre or choco install calibre.",
        "macos" => "Install Calibre: brew install --cask calibre.",
        "linux" => "Install Calibre: apt install calibre (or use your distro package manager)."
      },
      "poppler" => {
        "windows" => "Install Poppler and add pdftoppm/pdftotext to PATH; choco install poppler.",
        "macos" => "Install Poppler: brew install poppler.",
        "linux" => "Install Poppler: apt install poppler-utils (or use your distro package manager)."
      },
      "librsvg" => {
        "windows" => "Install librsvg and add rsvg-convert to PATH; choco install librsvg.",
        "macos" => "Install librsvg: brew install librsvg.",
        "linux" => "Install librsvg: apt install librsvg2-bin (or use your distro package manager)."
      },
      "xz" => {
        "windows" => "Install XZ Utils: winget install XZUtils.XZ or choco install xz.",
        "macos" => "Install XZ Utils: brew install xz.",
        "linux" => "Install XZ Utils: apt install xz-utils (or use your distro package manager)."
      },
      "bzip2" => {
        "windows" => "Install bzip2 with choco install bzip2, or use 7-Zip.",
        "macos" => "Install bzip2: brew install bzip2.",
        "linux" => "Install bzip2: apt install bzip2 (or use your distro package manager)."
      },
      "7zip" => {
        "windows" => "Install 7-Zip: winget install 7zip.7zip or choco install 7zip.",
        "macos" => "Install 7-Zip: brew install sevenzip.",
        "linux" => "Install 7-Zip: apt install p7zip-full (or use your distro package manager)."
      },
      "libvips" => {
        "windows" => "Install libvips and the ruby-vips gem; see https://www.libvips.org/install.html.",
        "macos" => "Install libvips: brew install vips.",
        "linux" => "Install libvips: apt install libvips42 (or use your distro package manager)."
      }
    }.freeze

    module_function

    # Finds the first executable from `names` (String or Array). An explicit
    # override through `env_var` takes precedence; when present but empty the
    # PATH scan continues normally.
    def find(names, env_var: nil)
      entries = Array(names).map { |name| name.to_s.strip }.reject(&:empty?)
      if env_var
        override = ENV[env_var].to_s.strip
        return resolve_explicit(override) unless override.empty?
      end

      entries.each do |name|
        found = search_in_path(name)
        return found if found
      end
      nil
    rescue StandardError
      nil
    end

    # Convenience wrapper matching the classic which() shape.
    def which(*names, env_var: nil)
      find(names, env_var: env_var)
    end

    # Runs `path args...` and returns the first capture of `pattern` from
    # combined stdout/stderr. Failures, missing binaries, and timeouts all
    # return nil instead of raising.
    def version(path, args = [], pattern = nil, timeout: 10)
      return nil if path.nil? || path.to_s.empty? || pattern.nil?

      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern.to_s)
      result = Cvt::Shell.run([path, *Array(args)], timeout: timeout)
      match = regexp.match("#{result.stdout}\n#{result.stderr}")
      return nil unless match

      match.captures.first || match[0]
    rescue StandardError
      nil
    end

    def platform
      return "windows" if Gem.win_platform?

      host_os = RbConfig::CONFIG["host_os"].to_s
      return "macos" if host_os.match?(/darwin|mac os/)

      "linux"
    end

    # Windows ships a filesystem tool called convert.exe; it must never be
    # mistaken for ImageMagick's Unix `convert` CLI.
    def convert_exe?(path)
      File.basename(path.to_s).downcase.match?(/\Aconvert(?:\.com|\.exe)?\z/)
    end

    # ImageMagick lookup shared by the backend and `--doctor`. On Windows only
    # `magick` is acceptable, even when CVT_BIN_MAGICK points at convert.exe.
    def imagemagick
      if platform == "windows"
        path = Cvt::Bin.find("magick", env_var: "CVT_BIN_MAGICK")
        path unless convert_exe?(path)
      else
        Cvt::Bin.find(%w[magick convert], env_var: "CVT_BIN_MAGICK")
      end
    end

    def hint(tool, platform: Cvt::Bin.platform)
      key = TOOL_ALIASES[tool.to_s.strip.downcase]
      hints = key && HINTS[key]
      if hints
        hints[platform.to_s] || hints["linux"]
      else
        generic_hint(tool, platform)
      end
    end

    def search_in_path(name)
      path_dirs.each do |directory|
        candidate_names(name).each do |candidate|
          path = File.expand_path(File.join(directory, candidate))
          return path if executable_file?(path)
        end
      end
      nil
    end
    private_class_method :search_in_path

    def resolve_explicit(value)
      return search_in_path(value) unless path_syntax?(value)

      candidate_names(value).map { |candidate| File.expand_path(candidate) }
                            .find { |candidate| executable_file?(candidate) }
    end
    private_class_method :resolve_explicit

    def path_syntax?(value)
      value.include?(File::SEPARATOR) ||
        (File::ALT_SEPARATOR && value.include?(File::ALT_SEPARATOR))
    end
    private_class_method :path_syntax?

    def candidate_names(name)
      return [name] unless platform == "windows"

      extensions = windows_extensions
      extension = File.extname(name).downcase
      return [name] if !extension.empty? && extensions.include?(extension)

      extensions.map { |suffix| "#{name}#{suffix}" } + [name]
    end
    private_class_method :candidate_names

    # PATHEXT is authoritative on Windows; the fixed list keeps lookups
    # working when the variable is missing or blank.
    def windows_extensions
      extensions = ENV["PATHEXT"].to_s.split(";")
                                 .map { |suffix| suffix.strip.downcase }
                                 .reject(&:empty?)
      extensions.empty? ? WINDOWS_SUFFIXES : extensions
    end
    private_class_method :windows_extensions

    def path_dirs
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                   .map { |directory| directory.to_s.gsub(/\A"|"\z/, "") }
                   .reject(&:empty?)
    end
    private_class_method :path_dirs

    def executable_file?(path)
      return false unless File.file?(path)
      # Ruby's executable bit is unreliable for .bat/.cmd (and unset for
      # extension-less probes), so a Windows executable extension is enough.
      if platform == "windows" && windows_extensions.include?(File.extname(path).downcase)
        return true
      end

      File.executable?(path)
    rescue StandardError
      false
    end
    private_class_method :executable_file?

    def generic_hint(tool, platform)
      name = tool.to_s.strip
      name = "the required engine" if name.empty?
      case platform.to_s
      when "windows"
        "Install #{name} with winget or choco, or download it from its official site."
      when "macos"
        "Install #{name} with brew or download it from its official site."
      else
        "Install #{name} with apt or your distro package manager, or download it from its official site."
      end
    end
    private_class_method :generic_hint
  end
end
