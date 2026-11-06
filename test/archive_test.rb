# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "minitest/autorun"
require "rubygems/package"
require "tmpdir"
require "zlib"
require "zip"

require "cvt"
require "cvt/adapters/archive/containers"
require "cvt/adapters/archive/tools"

# Task 11 coverage: container repacking (zip/tar/tgz), single-stream
# gz/xz/bz2 recompression, and archive safety limits. Stream tests skip when
# neither the native compressor nor 7-Zip is installed, so the suite still
# passes offline.
class ArchiveTest < Minitest::Test
  ENTRY_TIME = Time.at(1_600_000_000)

  def setup
    @backend = Cvt::Backends.load("native_archive")
    refute_nil @backend, "native_archive backend must load"
    @dir = Dir.mktmpdir("cvt-archive-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def path(name)
    File.join(@dir, name)
  end

  def convert(from, to, input, output, options = {})
    warnings = []
    @backend.convert(input, output, { "from" => from, "to" => to }.merge(options), warnings)
    [output, warnings]
  end

  def write_zip(target, files, directories: [])
    Zip::File.open(target, create: true) do |zip|
      directories.each { |name| zip.mkdir(name, 0o755) }
      files.each do |name, content|
        zip.get_output_stream(name, permissions: 0o644, time: ENTRY_TIME) do |out|
          out.write(content)
        end
      end
    end
    target
  end

  def write_tar(target)
    File.open(target, "wb") do |io|
      Gem::Package::TarWriter.new(io) do |tar|
        tar.add_file_simple("plain/a.txt", 0o644, 5) { |out| out.write("hello") }
      end
    end
    target
  end

  def write_tar_with(target, &block)
    File.open(target, "wb") do |io|
      Gem::Package::TarWriter.new(io) { |tar| block.call(tar) }
    end
    target
  end

  def zip_entries(source)
    entries = {}
    Zip::File.open(source) do |zip|
      zip.each do |entry|
        entries[entry.name] = entry.directory? ? nil : entry.get_input_stream.read
      end
    end
    entries
  end

  def tar_entries(source)
    entries = {}
    File.open(source, "rb") do |io|
      Gem::Package::TarReader.new(io) do |tar|
        tar.each do |entry|
          entries[entry.full_name] = [entry.directory? ? nil : entry.read, entry.header.mtime]
        end
      end
    end
    entries
  end

  def tar_gz_entries(source)
    entries = {}
    Zlib::GzipReader.open(source) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          entries[entry.full_name] = [entry.directory? ? nil : entry.read, entry.header.mtime]
        end
      end
    end
    entries
  end

  def write_gz(target, content)
    Zlib::GzipWriter.open(target) { |gz| gz.write(content) }
    target
  end

  def selection(format)
    Cvt::Adapters::Archive.select_tool(format)
  end

  def decompress_stream(source, format)
    case format
    when "gz"
      Zlib::GzipReader.open(source) { |gz| gz.read }
    else
      tool = selection(format)
      skip "#{format} compressor is not installed" unless tool
      if tool.seven_zip?
        Cvt::Shell.run([tool.path, "x", "-y", "-so", source]).stdout
      else
        Cvt::Shell.run([tool.path, "-dc", source]).stdout
      end
    end
  end

  def encrypt_zip!(target)
    data = File.binread(target)
    [["PK\x03\x04".b, 6], ["PK\x01\x02".b, 8]].each do |signature, offset|
      position = 0
      while (index = data.index(signature, position))
        flags = data.byteslice(index + offset, 2).unpack1("v") | 1
        data[index + offset, 2] = [flags].pack("v")
        position = index + 4
      end
    end
    File.binwrite(target, data)
  end

  def test_availability_covers_all_routes
    containers = %w[zip tar tgz]

    containers.product(containers).each do |from, to|
      next if from == to

      assert @backend.available_for?(from, to), "#{from} -> #{to} should be available"
    end
    assert @backend.available_for?("gz", "xz", ["xz"]) == !selection("xz").nil?
    assert @backend.available_for?("gz", "bz2", ["bzip2"]) == !selection("bzip2").nil?
    assert @backend.available_for?("xz", "bz2", ["xz", "bzip2"]) ==
           (!selection("xz").nil? && !selection("bzip2").nil?)

    refute @backend.available_for?("zip", "gz")
    refute @backend.available_for?("gz", "tar")
    refute @backend.available_for?("tar", "tar"), "same-format routes are not conversions"
    refute @backend.available_for?("xz", "tar")
    assert_equal "native_archive", @backend.id
    assert @backend.available?
    assert_match(/rubyzip|zlib/, @backend.version.to_s)
  end

  def test_zip_to_tgz_preserves_paths_content_and_mtime
    source = write_zip(path("bundle.zip"), { "docs/a.txt" => "alpha", "docs/b.txt" => "beta" },
                       directories: ["docs"])
    output, warnings = convert("zip", "tgz", source, path("bundle.tar.gz"))

    assert File.file?(output)
    entries = tar_gz_entries(output)
    assert_equal "alpha", entries.fetch("docs/a.txt").first
    assert_equal "beta", entries.fetch("docs/b.txt").first
    assert_equal ENTRY_TIME.to_i, entries.fetch("docs/a.txt").last
    assert entries.key?("docs/"), "directories should be repacked as entries"
    assert warnings.any? { |warning| warning["code"] == "archive_metadata_loss" }
  end

  def test_tgz_to_zip_round_trip
    source = write_zip(path("round.zip"), { "nested/file.txt" => "payload" })
    tgz = path("round.tar.gz")
    convert("zip", "tgz", source, tgz)
    output, = convert("tgz", "zip", tgz, path("round-out.zip"))

    entries = zip_entries(output)
    assert_equal "payload", entries.fetch("nested/file.txt")
  end

  def test_tar_to_zip_and_zip_to_tar
    tar = write_tar(path("plain.tar"))
    zipped, = convert("tar", "zip", tar, path("plain.zip"))
    assert_equal({ "plain/a.txt" => "hello" }, zip_entries(zipped))

    zip = write_zip(path("plain2.zip"), { "file.txt" => "zipdata" })
    plain_tar, = convert("zip", "tar", zip, path("plain2.tar"))
    assert_equal "zipdata", tar_entries(plain_tar).fetch("file.txt").first
  end

  def test_gz_to_xz_when_available
    skip "xz and 7-Zip are not installed" unless selection("xz")
    content = "compress me " * 512
    source = write_gz(path("data.gz"), content)
    output, = convert("gz", "xz", source, path("data.xz"))

    assert File.file?(output)
    assert_equal content, decompress_stream(output, "xz")
  end

  def test_gz_to_bz2_when_available
    skip "bzip2 and 7-Zip are not installed" unless selection("bzip2")
    content = "bzip2 body " * 256
    source = write_gz(path("data2.gz"), content)
    output, = convert("gz", "bz2", source, path("data.bz2"))

    assert File.file?(output)
    assert_equal content, decompress_stream(output, "bz2")
  end

  def test_xz_falls_back_to_7z_in_availability_check
    return unless selection("7z")

    original = ENV["CVT_BIN_XZ"]
    ENV["CVT_BIN_XZ"] = File.join(@dir, "missing-xz")
    begin
      assert @backend.available_for?("gz", "xz", ["xz"]), "7-Zip should satisfy the xz route"
    ensure
      original.nil? ? ENV.delete("CVT_BIN_XZ") : ENV["CVT_BIN_XZ"] = original
    end
  end

  def test_seven_zip_fallback_recompresses_streams
    original = ENV["CVT_BIN_XZ"]
    return unless selection("7z")

    content = "seven zip fallback " * 64
    source = write_gz(path("fallback.gz"), content)
    output = path("fallback.xz")
    ENV["CVT_BIN_XZ"] = File.join(@dir, "missing-xz")
    begin
      convert("gz", "xz", source, output)
      assert_equal content, decompress_stream(output, "xz")
    ensure
      original.nil? ? ENV.delete("CVT_BIN_XZ") : ENV["CVT_BIN_XZ"] = original
    end
  end

  def test_rejects_parent_directory_entries
    source = write_zip(path("evil.zip"), { "../evil.txt" => "nope", "safe.txt" => "ok" })
    error = assert_raises(Cvt::Error) { convert("zip", "tgz", source, path("evil.tar.gz")) }

    assert_equal "unsafe_archive", error.code
    assert_equal 5, error.exit_code
    refute File.exist?(path("evil.tar.gz")), "no output should remain after an unsafe entry"
  end

  def test_rejects_absolute_tar_entries
    source = write_tar_with(path("absolute.tar")) { |tar| tar.add_file_simple("/abs.txt", 0o644, 1) { |out| out.write("x") } }
    error = assert_raises(Cvt::Error) { convert("tar", "zip", source, path("absolute.zip")) }

    assert_equal "unsafe_archive", error.code
    refute File.exist?(path("absolute.zip"))
  end

  def test_rejects_symlink_tar_entries
    source = write_tar_with(path("links.tar")) { |tar| tar.add_symlink("link", "/etc/passwd", 0o777) }
    error = assert_raises(Cvt::Error) { convert("tar", "zip", source, path("links.zip")) }

    assert_equal "unsafe_archive", error.code
    refute File.exist?(path("links.zip"))
  end

  def test_rejects_encrypted_zip
    source = write_zip(path("secret.zip"), { "secret.txt" => "hidden" })
    encrypt_zip!(source)
    error = assert_raises(Cvt::Error) { convert("zip", "tar", source, path("secret.tar")) }

    assert_equal "conversion_failed", error.code
    assert_match(/decrypt/i, error.hint)
    refute File.exist?(path("secret.tar"))
  end

  def test_enforces_max_size_while_repacking
    source = write_zip(path("large.zip"), { "large.bin" => "x" * 4096 })
    error = assert_raises(Cvt::Error) do
      convert("zip", "tgz", source, path("large.tar.gz"), "max_size" => 1024)
    end

    assert_equal "conversion_failed", error.code
    assert_match(/max-size/, error.message)
    refute File.exist?(path("large.tar.gz"))
  end

  def test_max_size_zero_is_unlimited
    source = write_zip(path("limitless.zip"), { "data.bin" => "y" * 4096 })
    output, = convert("zip", "tar", source, path("limitless.tar"), "max_size" => 0)
    assert_equal ("y" * 4096), tar_entries(output).fetch("data.bin").first
  end

  def test_single_stream_max_size_applies_to_decompressed_data
    skip "xz and 7-Zip are not installed" unless selection("xz")
    source = write_gz(path("big.gz"), "z" * 4096)
    error = assert_raises(Cvt::Error) do
      convert("gz", "xz", source, path("big.xz"), "max_size" => 1024)
    end

    assert_equal "conversion_failed", error.code
    assert_match(/max-size/, error.message)
    refute File.exist?(path("big.xz"))
  end
end
