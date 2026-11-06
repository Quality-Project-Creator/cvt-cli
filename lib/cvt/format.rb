# frozen_string_literal: true

module Cvt
  # A canonical format declared in data/formats.yml. Formats are immutable;
  # registry lookup accepts canonical IDs, aliases, and extensions.
  class Format
    CATEGORIES = %w[image audio video document data archive subtitle].freeze

    attr_reader :id, :category, :extensions, :mime, :aliases
    attr_reader :read, :write

    def initialize(id:, category:, extensions:, mime:, read:, write:, aliases: [])
      @id = id.to_s.downcase.freeze
      @category = category.to_s.freeze
      @extensions = extensions.map { |ext| ext.to_s.downcase.freeze }.freeze
      @mime = mime.to_s.freeze
      @read = read
      @write = write
      @aliases = aliases.map { |name| name.to_s.downcase.freeze }.freeze
      freeze
    end

    def readable?
      read
    end

    def writable?
      write
    end

    def to_h
      {
        "id" => id,
        "category" => category,
        "extensions" => extensions,
        "mime" => mime,
        "aliases" => aliases,
        "read" => read,
        "write" => write
      }
    end
  end
end
