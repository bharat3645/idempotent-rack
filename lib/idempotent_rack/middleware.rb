# frozen_string_literal: true

require "digest"
require "json"
require "stringio"

module IdempotentRack
  # Rack middleware: dedupes retried POST/PUT/PATCH requests against an
  # Idempotency-Key header, so a client retry after a dropped connection
  # (or a double-click, or a naive retry loop) replays the first request's
  # actual response instead of re-running it - the standard protection
  # against double-charging a card, double-sending a webhook, or double-
  # creating a resource.
  #
  # A request with no Idempotency-Key header passes through untouched -
  # this middleware never *requires* clients to use it, it only acts when
  # they opt in.
  class Middleware
    DEFAULT_METHODS = %w[POST PUT PATCH].freeze
    DEFAULT_HEADER_ENV_KEY = "HTTP_IDEMPOTENCY_KEY" # the "Idempotency-Key" HTTP header, as Rack env sees it

    def initialize(app, store: MemoryStore.new, methods: DEFAULT_METHODS, header_env_key: DEFAULT_HEADER_ENV_KEY)
      @app = app
      @store = store
      @methods = methods
      @header_env_key = header_env_key
    end

    def call(env)
      return @app.call(env) unless @methods.include?(env["REQUEST_METHOD"])

      key = env[@header_env_key]
      return @app.call(env) if key.nil? || key.empty?

      body = read_and_rewind_body(env)
      fingerprint = fingerprint_for(env, body)

      claim =
        begin
          @store.claim(key, fingerprint)
        rescue KeyInUseError => e
          return error_response(409, "idempotency_key_in_use", e.message)
        rescue KeyConflictError => e
          return error_response(422, "idempotency_key_conflict", e.message)
        end

      return replay_response(claim) if claim.is_a?(Array)

      run_and_store(env, key)
    end

    private

    def run_and_store(env, key)
      status, headers, body_enum = @app.call(env)
      buffered = []
      body_enum.each { |chunk| buffered << chunk }
      body_enum.close if body_enum.respond_to?(:close)

      response = [status, headers, buffered]
      @store.complete!(key, response)
      response
    rescue StandardError
      # The app blew up before producing a response at all - free the key
      # so a retry gets a real chance instead of a permanent 409. A
      # request that completes (even with a 4xx/5xx *response*) is still
      # cached above, matching Stripe's documented behavior of caching
      # failures too - only an unhandled exception releases the key.
      @store.release!(key)
      raise
    end

    def replay_response(response)
      status, headers, body = response
      replay_headers = headers.merge("Idempotency-Replayed" => "true")
      [status, replay_headers, body]
    end

    # Reads the request body exactly once and rewinds rack.input so the
    # downstream app can still read it - Rack apps universally expect to
    # be able to read the body themselves, and middleware that consumes
    # it without rewinding silently breaks every app behind it.
    def read_and_rewind_body(env)
      input = env["rack.input"]
      return "" unless input

      body = input.read
      if input.respond_to?(:rewind)
        input.rewind
      else
        env["rack.input"] = StringIO.new(body)
      end
      body
    end

    def fingerprint_for(env, body)
      Digest::SHA256.hexdigest("#{env['REQUEST_METHOD']}\n#{env['PATH_INFO']}\n#{body}")
    end

    def error_response(status, code, message)
      body = JSON.generate({ "error" => { "code" => code, "message" => message } })
      [status, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
    end
  end
end
