# frozen_string_literal: true

module Cvt
  # One declarative conversion edge, expanded from data/routes.yml. `priority`
  # uses the convention that lower numbers are preferred; `lossy` marks
  # conversions that lose information; `requirements` lists route-level
  # external binaries (for example "xz" or "bzip2").
  class Route
    attr_reader :backend, :from, :to, :priority, :requirements

    def initialize(backend:, from:, to:, priority: 0, lossy: false, requirements: [])
      @backend = backend.to_s.freeze
      @from = from.to_s.freeze
      @to = to.to_s.freeze
      @priority = Integer(priority)
      @lossy = !!lossy
      @requirements = requirements.map { |name| name.to_s.freeze }.freeze
      freeze
    end

    def lossy?
      @lossy
    end

    def to_h
      { "backend" => backend, "from" => from, "to" => to }
    end

    def sort_key
      [priority, backend, from, to]
    end
  end
end
