# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "cvt"

# Task 13 coverage for platform-sensitive paths. These run on Linux, macOS, and
# Windows; Windows-only branches are driven through stubs so the guards are
# checked on every CI host instead of being skipped on Linux.
class CrossPlatformTest < Minitest::Test
  EXE = File.expand_path("../exe/cvt", __dir__)

  def test_csv_to_json_with_spaces_and_unicode_in_paths
    Dir.mktmpdir("cvt-cross-platform-") do |root|
      directory = File.join(root, "spaced ünïcode 目录")
      FileUtils.mkdir_p(directory)
      source = File.join(directory, "data file 数据.csv")
      target = File.join(directory, "data file 数据.json")
      File.write(source, "name,age\nAlice,30\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXE, source, target)

      assert_equal 0, status.exitstatus, "cvt failed:\n#{stdout}\n#{stderr}"
      assert_equal "", stderr
      document = YAML.safe_load(stdout.dup.force_encoding(Encoding::UTF_8))
      assert_equal source, document["input"]["path"]
      assert_equal target, document["output"]["path"]
      assert_equal "json", document["output"]["format"]
      assert_equal [{ "name" => "Alice", "age" => "30" }], JSON.parse(File.read(target))
    end
  end

  def test_windows_pathex_and_explicit_override_extension_expansion
    Dir.mktmpdir("cvt-pathex-") do |dir|
      tool = File.join(dir, "cvt-fake-tool.exe")
      File.write(tool, "")
      saved = ENV.values_at("PATH", "PATHEXT", "CVT_TEST_BIN")
      begin
        ENV["PATH"] = dir
        ENV["PATHEXT"] = ".CMD;.EXE"
        ENV["CVT_TEST_BIN"] = File.join(dir, "cvt-fake-tool")
        Gem.stub(:win_platform?, true) do
          assert_equal tool, Cvt::Bin.find("cvt-fake-tool")
          assert_equal tool, Cvt::Bin.find("missing-tool", env_var: "CVT_TEST_BIN")
        end
      ensure
        ENV.keys.each { |key| ENV.delete(key) if %w[PATH PATHEXT CVT_TEST_BIN].include?(key) }
        saved.each_with_index do |value, index|
          key = %w[PATH PATHEXT CVT_TEST_BIN][index]
          ENV[key] = value if value
        end
      end
    end
  end

  def test_windows_imagemagick_lookup_never_returns_convert_exe
    convert = Gem.win_platform? ? 'C:\Windows\System32\convert.exe' : "/usr/bin/convert"

    Cvt::Bin.stub(:find, proc { |*_args| convert }) do
      Gem.stub(:win_platform?, true) do
        assert Cvt::Bin.convert_exe?(convert)
        assert_nil Cvt::Bin.imagemagick
      end
    end

    magick = Gem.win_platform? ? 'C:\Program Files\ImageMagick\magick.exe' : "/usr/bin/magick"
    Cvt::Bin.stub(:find, proc { |*_args| magick }) do
      Gem.stub(:win_platform?, true) do
        assert_equal magick, Cvt::Bin.imagemagick
      end
    end
  end

  def test_windows_shell_maps_term_to_kill
    calls = []
    Process.stub(:kill, proc { |signal, pid| calls << [signal, pid] }) do
      Gem.stub(:win_platform?, true) { Cvt::Shell.kill_process(4242, "TERM") }
    end

    assert_equal [["KILL", 4242]], calls
  end

  def test_libreoffice_user_installation_url_handles_windows_drive_paths
    backend = Cvt::Backends.load("libreoffice")
    refute_nil backend

    assert_equal "file:///tmp/cvt/profile",
                 backend.send(:user_installation_url, "/tmp/cvt/profile")
    assert_equal "file:///C:/Users/me/cvt/profile",
                 backend.send(:user_installation_url, 'C:\Users\me\cvt\profile')
  end
end
