# frozen_string_literal: true

# Reference: XZ Utils (0BSD) https://tukaani.org/xz
# Reference: bzip2 (bzip2 license) https://sourceware.org/bzip2
# Reference: 7-Zip (LGPL-2.1+) https://www.7-zip.org

require_relative "../../bin"

module Cvt
  module Adapters
    # Command-line helpers for the single-stream compressors. Every lookup is
    # a Ruby PATH scan (no shell) and a missing primary binary falls back to
    # 7-Zip before the route is declared unavailable.
    module Archive
      TOOL_SPECS = {
        "xz" => { names: %w[xz], env_var: "CVT_BIN_XZ" },
        "bzip2" => { names: %w[bzip2], env_var: "CVT_BIN_BZIP2" },
        "7z" => { names: %w[7z 7za 7zz], env_var: "CVT_BIN_SEVENZIP" }
      }.freeze

      # Format ids whose tool is named differently ("bz2" is produced by the
      # bzip2 binary). Without this mapping the bz2 routes could not find
      # bzip2 and only worked when 7-Zip happened to be installed.
      FORMAT_TOOLS = { "bz2" => "bzip2" }.freeze

      Selection = Struct.new(:tool, :path, keyword_init: true) do
        def seven_zip?
          tool == "7z"
        end
      end

      module_function

      # Maps a format id to the tool that produces it.
      def tool_name(name)
        FORMAT_TOOLS.fetch(name.to_s, name.to_s)
      end

      def tool_path(name)
        spec = TOOL_SPECS[tool_name(name)]
        return nil unless spec

        Cvt::Bin.find(spec[:names], env_var: spec[:env_var])
      end

      # Resolves a route requirement ("xz" or "bzip2") to a runnable tool,
      # preferring the native binary and falling back to 7-Zip.
      def select_tool(name)
        direct = tool_path(name)
        return Selection.new(tool: tool_name(name), path: direct) if direct

        fallback = tool_path("7z")
        fallback && Selection.new(tool: "7z", path: fallback)
      end

      def requirements_available?(requirements)
        Array(requirements).all? do |name|
          next false unless TOOL_SPECS.key?(tool_name(name))

          !select_tool(name).nil?
        end
      end
    end
  end
end
