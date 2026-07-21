$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "idempotent_rack"
require "minitest/autorun"
require "json"
require "stringio"

module RackTestHelpers
  # Builds a minimal, spec-compliant-enough Rack env by hand - no rack gem
  # needed, matching this account's zero-dependency convention (see
  # acts-as-mcp's test_helper.rb for the sibling pattern this mirrors).
  def rack_env(method: "POST", path: "/charges", body: "", headers: {})
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  # A downstream "app" for the middleware to wrap. call_count lets tests
  # assert the real app ran (or didn't) a specific number of times -
  # that's the actual thing idempotency is supposed to guarantee, not
  # just "the response looked right once."
  class CountingApp
    attr_reader :call_count, :received_bodies

    def initialize(&block)
      @call_count = 0
      @received_bodies = []
      @block = block || ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok #{@call_count}"]] }
    end

    def call(env)
      @call_count += 1
      @received_bodies << env["rack.input"].read
      env["rack.input"].rewind
      @block.call(env)
    end
  end
end
