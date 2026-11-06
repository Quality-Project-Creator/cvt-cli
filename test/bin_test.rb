# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "cvt"

class BinTest < Minitest::Test
  COMMON_TOOLS = %w[
    magick convert ffmpeg pandoc soffice ebook-convert
    pdftoppm pdftotext rsvg-convert xz bzip2 7z vips unknown-tool
  ].freeze

  def with_env(values)
    saved = {}
    values.each do |key, value|
      saved[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def create_tool(directory, name, executable: true)
    filename = Gem.win_platform? ? "#{name}.exe" : name
    path = File.join(directory, filename)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path) if executable && !Gem.win_platform?
    path
  end

  def test_find_scans_path_and_returns_absolute_executable
    Dir.mktmpdir("cvt-bin") do |dir|
      path = create_tool(dir, "cvt-test-tool")
      with_env("PATH" => dir) do
        assert_equal File.expand_path(path), Cvt::Bin.find("cvt-test-tool")
        assert_equal File.expand_path(path), Cvt::Bin.find(["missing-tool", "cvt-test-tool"])
        assert_equal File.expand_path(path), Cvt::Bin.which("cvt-test-tool")
      end
    end
  end

  def test_env_override_wins_over_path_scan
    Dir.mktmpdir("cvt-bin") do |dir|
      path = create_tool(dir, "override-tool")
      with_env("PATH" => File.join(dir, "empty"), "CVT_TEST_BIN_OVERRIDE" => path) do
        assert_equal File.expand_path(path), Cvt::Bin.find("missing-tool", env_var: "CVT_TEST_BIN_OVERRIDE")
      end
    end
  end

  def test_env_override_must_be_executable
    skip "executable bit semantics differ on Windows" if Gem.win_platform?

    Dir.mktmpdir("cvt-bin") do |dir|
      path = create_tool(dir, "not-executable", executable: false)
      with_env("PATH" => dir, "CVT_TEST_BIN_OVERRIDE" => path) do
        assert_nil Cvt::Bin.find("not-executable", env_var: "CVT_TEST_BIN_OVERRIDE")
      end
    end
  end

  def test_missing_name_returns_nil
    with_env("PATH" => "", "CVT_TEST_BIN_OVERRIDE" => "") do
      assert_nil Cvt::Bin.find("cvt-definitely-missing")
      assert_nil Cvt::Bin.find([])
    end
  end

  def test_platform_is_known_value
    assert_includes %w[windows macos linux], Cvt::Bin.platform
  end

  def test_hints_are_non_empty_for_common_tools_and_platforms
    %w[windows macos linux].each do |platform|
      COMMON_TOOLS.each do |tool|
        hint = Cvt::Bin.hint(tool, platform: platform)
        assert_kind_of String, hint
        refute_empty hint
        assert_match(/Install/, hint)
      end
    end
  end

  def test_version_returns_first_capture
    output = Cvt::Bin.version(
      RbConfig.ruby,
      ["-e", "puts 'tool version 4.5.6'"],
      /version (\d+\.\d+\.\d+)/
    )
    assert_equal "4.5.6", output
  end

  def test_version_reads_stderr_and_never_raises
    output = Cvt::Bin.version(
      RbConfig.ruby,
      ["-e", "warn 'tool version 9.9.9'"],
      /version (\d+\.\d+\.\d+)/
    )
    assert_equal "9.9.9", output

    assert_nil Cvt::Bin.version("/definitely/missing/tool", [], /anything/)
    assert_nil Cvt::Bin.version(nil, [], /anything/)
    assert_nil Cvt::Bin.version(RbConfig.ruby, ["-e", "sleep 2"], /never/, timeout: 0.2)
  end
end
