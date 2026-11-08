#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds a self-contained `cvt` executable for the current platform with
# Tebako (runtime and gems inside the package), runs functional smoke tests,
# measures size and startup, and applies size optimizations only when they
# keep the binary working and fast.
#
# Usage: ruby script/build_standalone.rb [--skip-format-comparison] [--skip-upx]
#
# Reference: tebako (BSD-2-Clause) https://github.com/tamatebako/tebako
# Reference: UPX (GPL-2.0-or-later, compressed-output exception) https://github.com/upx/upx

require "digest"
require "English"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")
require "cvt/version"

VERSION = Cvt::VERSION
RUBY_RUNTIME = ENV.fetch("CVT_RUBY_RUNTIME", "3.3.12")
TEBAKO_VERSION = ENV.fetch("CVT_TEBAKO_VERSION", "2.8.73")
DIST = File.join(ROOT, "dist")
STAGE = File.join(ROOT, "build", "standalone")
VENDOR_CACHE = File.join(ROOT, "build", "vendor-bundle")
STAGE_ENTRIES = %w[exe lib data].freeze
SIZE_GAIN_MIN = 0.05
STARTUP_SLOWDOWN_MAX = 1.2

def log(message)
  puts "[standalone] #{message}"
  $stdout.flush
end

def fail!(message)
  warn "[standalone] ERROR: #{message}"
  exit 1
end

def run!(*command, env: {}, chdir: ROOT)
  log "run: #{command.join(' ')}"
  ok = system(env, *command, chdir: chdir)
  fail!("#{command.first} failed") unless ok
end

def capture!(*command, env: {}, chdir: ROOT)
  out, err, status = Open3.capture3(env, *command, chdir: chdir)
  fail!("#{command.join(' ')} failed:\n#{err}") unless status.success?

  out
end

def host_cpu
  cpu = RbConfig::CONFIG["host_cpu"].to_s
  return "x86_64" if cpu.match?(/x86_64|amd64|x64/)
  return "arm64" if cpu.match?(/aarch64|arm64/)
  return "x86" if cpu.match?(/i[3-6]86/)

  cpu
end

def platform
  os = Gem.win_platform? ? "windows" : RbConfig::CONFIG["host_os"].to_s
  return "windows-#{host_cpu}" if Gem.win_platform?
  return "macos-#{host_cpu}" if os.match?(/darwin/)
  return "linux-#{host_cpu}" if os.match?(/linux/)

  fail!("unsupported host OS: #{os}")
end

def binary_name
  base = "cvt-#{VERSION}-#{platform}"
  Gem.win_platform? ? "#{base}.exe" : base
end

def prepare_stage
  FileUtils.rm_rf(STAGE)
  FileUtils.mkdir_p(STAGE)
  STAGE_ENTRIES.each do |entry|
    source = File.join(ROOT, entry)
    fail!("missing #{entry}") unless File.exist?(source)

    FileUtils.cp_r(source, STAGE)
  end
  generate_gemfile
  lock_bundle
  log "staged #{STAGE_ENTRIES.join(', ')}"
end

# Tebako 2.8 rejects a Gemfile that uses `gemspec`, so the package gets a
# plain Gemfile with the exact runtime gems pinned from the tested lockfile.
def generate_gemfile
  spec = Gem::Specification.load(File.join(ROOT, "cvt-cli.gemspec"))
  fail!("cannot load cvt-cli.gemspec") unless spec

  versions = {}
  File.foreach(File.join(ROOT, "Gemfile.lock")) do |line|
    match = line.match(/^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)$/)
    # Lock entries for native gems carry a platform suffix, for example
    # "1.19.4-x86_64-linux-gnu"; a Gemfile pin needs the bare version.
    versions[match[1]] = match[2].split("-").first if match
  end

  gems = spec.runtime_dependencies.map do |dependency|
    requirement = versions[dependency.name] || dependency.requirement.to_s
    "gem #{dependency.name.inspect}, #{requirement.inspect}"
  end
  File.write(File.join(STAGE, "Gemfile"), "source \"https://rubygems.org\"\n\n#{gems.join("\n")}\n")
end

# Resolve the stage lockfile from the gems already installed for the host
# build, so no index fetch happens here. Tebako's deploy then installs the
# pinned set into its own runtime; CI runners have a fast network for that.
def lock_bundle
  env = { "BUNDLE_WITHOUT" => "development:test" }
  local = system(env, RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: STAGE)
  unless local
    log "local gem resolution failed; falling back to the full index"
    run!(RbConfig.ruby, "-S", "bundle", "lock", "--full-index", env: env, chdir: STAGE)
  end
  FileUtils.mkdir_p(File.join(STAGE, ".bundle"))
  File.write(File.join(STAGE, ".bundle", "config"),
             "---\nBUNDLE_FROZEN: \"true\"\nBUNDLE_DEPLOYMENT: \"true\"\nBUNDLE_PATH: \"vendor/bundle\"\n")
end

def tebako_store
  return ENV["TEBAKO_HOME"] if ENV["TEBAKO_HOME"]

  if Gem.win_platform?
    File.join(ENV.fetch("LOCALAPPDATA"), "tebako")
  else
    File.join(Dir.home, ".tebako")
  end
end

# Tebako deploys the bundle into its packaging environment but packs the
# project tree from disk. Import the runtime-built gems into the project so
# the image actually carries them.
def import_vendor_bundle
  source = File.join(tebako_store, "o", "s", "local", "vendor", "bundle")
  fail!("tebako deployed no bundle at #{source}") unless Dir.exist?(source)

  dest = File.join(STAGE, "vendor", "bundle")
  FileUtils.rm_rf(dest)
  FileUtils.mkdir_p(File.dirname(dest))
  FileUtils.cp_r(source, dest)
  FileUtils.rm_rf(File.join(dest, "cache"))
  FileUtils.rm_rf(VENDOR_CACHE)
  FileUtils.cp_r(dest, VENDOR_CACHE)
  log "imported runtime gems from #{source}"
end

def press(format, output)
  FileUtils.mkdir_p(File.dirname(output))
  # Each press seeds the payload cache; a stale seed for the same name but
  # other bytes makes the bootstrap print a digest-mismatch warning.
  cache_name = File.basename(output).sub(/\.(limnifs|dwarfs)\z/, "")
  FileUtils.rm_rf(File.join(tebako_store, "payloads", cache_name))
  run!(
    "tebako", "press",
    "-r", STAGE,
    "-e", "exe/cvt",
    "-o", output,
    "-m", "self-contained",
    "-R", RUBY_RUNTIME,
    "--format", format,
    "--no-sign",
    "--quiet-notices",
    "--exclude", "test/**",
    "--exclude", ".git/**",
    "--exclude", "build/**",
    "--exclude", "dist/**"
  )
  fail!("press produced no output") unless File.file?(output) && File.size(output).positive?

  output
end

def smoke(binary)
  version = capture!(binary, "--version")
  fail!("--version is wrong:\n#{version}") unless version.include?("version: #{VERSION}")

  formats = capture!(binary, "--formats")
  fail!("--formats is wrong:\n#{formats}") unless formats.include?("count: 56")

  Dir.mktmpdir("cvt-smoke-") do |dir|
    csv = File.join(dir, "sample.csv")
    File.write(csv, "name,role\nalice,dev\nbob,ops\n")

    json = File.join(dir, "sample.json")
    capture!(binary, csv, json)
    fail!("csv -> json failed") unless File.read(json).include?('"alice"')

    xlsx = File.join(dir, "sample.xlsx")
    capture!(binary, csv, xlsx)
    fail!("csv -> xlsx failed") unless File.file?(xlsx) && File.size(xlsx).positive?
  end

  capture!(binary, "--doctor")
  log "smoke tests passed"
end

def startup_ms(binary, runs: 5)
  samples = Array.new(runs) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    system(binary, "--version", out: File::NULL, err: File::NULL)
    fail!("#{binary} --version failed") unless $CHILD_STATUS.success?

    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
  samples.sort[samples.size / 2]
end

def upx_available?
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
    path = File.join(dir, Gem.win_platform? ? "upx.exe" : "upx")
    File.executable?(path)
  end
end

def maybe_upx(binary, baseline_ms)
  return [binary, "skipped (macOS)" ] if RbConfig::CONFIG["host_os"].match?(/darwin/)
  return [binary, "skipped (upx not installed)"] unless upx_available?

  packed = "#{binary}.upx"
  FileUtils.cp(binary, packed)
  run!("upx", "--best", "--lzma", packed)
  run!("upx", "-t", packed)

  original = File.size(binary)
  packed_size = File.size(packed)
  gain = 1.0 - (packed_size.to_f / original)
  packed_ms = startup_ms(packed)

  if gain < SIZE_GAIN_MIN
    FileUtils.rm_f(packed)
    return [binary, format("skipped (gain %.1f%% < %.0f%%)", gain * 100, SIZE_GAIN_MIN * 100)]
  end
  if packed_ms > baseline_ms * STARTUP_SLOWDOWN_MAX
    FileUtils.rm_f(packed)
    return [binary, format("skipped (startup %.0fms > %.0fms)", packed_ms, baseline_ms * STARTUP_SLOWDOWN_MAX)]
  end

  begin
    smoke(packed)
  rescue SystemExit
    FileUtils.rm_f(packed)
    return [binary, "skipped (smoke test failed)"]
  end

  FileUtils.rm_f(binary)
  FileUtils.mv(packed, binary)
  FileUtils.chmod(0o755, binary)
  [binary, format("applied (%.1f%% smaller)", gain * 100)]
end

def checksum(binary)
  digest = Digest::SHA256.file(binary).hexdigest
  path = "#{binary}.sha256"
  File.write(path, "#{digest}  #{File.basename(binary)}\n")
  path
end

skip_format_comparison = ARGV.include?("--skip-format-comparison")
skip_upx = ARGV.include?("--skip-upx")

FileUtils.mkdir_p(DIST)
prepare_stage

name = binary_name
if Dir.exist?(VENDOR_CACHE)
  FileUtils.mkdir_p(File.join(STAGE, "vendor"))
  FileUtils.cp_r(VENDOR_CACHE, File.join(STAGE, "vendor", "bundle"))
  log "reused cached runtime gems from #{VENDOR_CACHE}"
else
  warmup = File.join(DIST, ".warmup")
  press("limnifs", warmup)
  FileUtils.rm_f(warmup)
  import_vendor_bundle
end

limnifs = File.join(DIST, "#{name}.limnifs")
press("limnifs", limnifs)
smoke(limnifs)
limnifs_ms = startup_ms(limnifs)

chosen = limnifs
format_note = "limnifs"
unless skip_format_comparison
  dwarfs = File.join(DIST, "#{name}.dwarfs")
  press("dwarfs", dwarfs)
  smoke(dwarfs)
  dwarfs_ms = startup_ms(dwarfs)
  gain = 1.0 - (File.size(dwarfs).to_f / File.size(limnifs))
  log format("dwarfs is %.1f%% smaller, startup %.0fms vs %.0fms", gain * 100, dwarfs_ms, limnifs_ms)
  if gain >= SIZE_GAIN_MIN && dwarfs_ms <= limnifs_ms * STARTUP_SLOWDOWN_MAX
    chosen = dwarfs
    format_note = "dwarfs"
  end
  FileUtils.rm_f(chosen == dwarfs ? limnifs : dwarfs)
end

final = File.join(DIST, name)
FileUtils.mv(chosen, final)
FileUtils.chmod(0o755, final)
final_ms = startup_ms(final)

upx_note = "skipped"
unless skip_upx
  final, upx_note = maybe_upx(final, final_ms)
  final_ms = startup_ms(final) if upx_note.start_with?("applied")
end

checksum(final)
File.write(File.join(DIST, "sizes.txt"),
           "#{name}\tformat=#{format_note}\tbytes=#{File.size(final)}\tstartup_ms=#{final_ms}\tupx=#{upx_note}\n")
log "built #{final} (#{File.size(final)} bytes, format=#{format_note}, startup=#{final_ms}ms, upx=#{upx_note})"
