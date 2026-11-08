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

      # Stream formats whose name differs from the tool that handles them.
      FORMAT_TOOLS = { "bz2" => "bzip2" }.freeze

      Selection = Struct.new(:tool, :path, keyword_init: true) do
        def seven_zip?
          tool == "7z"
        end
      end

      module_function

      def tool_path(name)
        spec = TOOL_SPECS[name.to_s]
        return nil unless spec

        Cvt::Bin.find(spec[:names], env_var: spec[:env_var])
      end

      # Resolves a route requirement ("xz" or "bzip2") to a runnable tool,
      # preferring the native binary and falling back to 7-Zip. Stream format
      # names such as "bz2" are mapped to the tool that handles them.
      def select_tool(name)
        tool = FORMAT_TOOLS.fetch(name.to_s, name.to_s)
        direct = tool_path(tool)
        return Selection.new(tool: tool, path: direct) if direct

        fallback = tool_path("7z")
        fallback && Selection.new(tool: "7z", path: fallback)
      end

      def requirements_available?(requirements)
        Array(requirements).all? do |name|
          tool = FORMAT_TOOLS.fetch(name.to_s, name.to_s)
          next false unless TOOL_SPECS.key?(tool)

          !select_tool(tool).nil?
        end
      end
    end
  end
end
