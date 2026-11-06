# frozen_string_literal: true

require_relative "lib/cvt/version"

Gem::Specification.new do |spec|
  spec.name = "cvt-cli"
  spec.version = Cvt::VERSION
  spec.summary = "Convert files between 56 formats with a stable YAML result contract"
  spec.description = "A single-command file format converter that reuses mature native gems and external engines."
  spec.authors = ["CVT contributors"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb"] + Dir["data/*.yml"] + Dir["exe/*"] +
               %w[README.md LICENSE ATTRIBUTION.md].select { |path| File.exist?(path) }
  spec.bindir = "exe"
  spec.executables = ["cvt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "marcel", "~> 1.0"
  spec.add_dependency "nokogiri", ">= 1.15"
  spec.add_dependency "kramdown", ">= 2.4"
  spec.add_dependency "toml-rb", ">= 2.2"
  spec.add_dependency "srt", ">= 0.1"
  spec.add_dependency "rubyzip", ">= 2.3"
  spec.add_dependency "pdf-reader", ">= 2.12"
  spec.add_dependency "prawn", ">= 2.4"
  spec.add_dependency "caxlsx", ">= 4.1"
  spec.add_dependency "roo", ">= 2.10"
  spec.add_dependency "mini_magick", ">= 4.12"
  spec.add_dependency "ruby-vips", "~> 2.1"
end
