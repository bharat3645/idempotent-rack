# frozen_string_literal: true

require "json"
require "base64"

module IdempotentRack
  # Serializes a cached [status, headers, body_chunks] response tuple to and
  # from a JSON string, for the three stores that persist outside the Ruby
  # process (FileStore, RedisStore, ActiveRecordStore).
  #
  # Plain `JSON.generate(response)` works fine for a text response, but a
  # Rack response body is an array of bytestrings, and any store that
  # round-trips one through JSON.generate/JSON.parse directly raises
  # JSON::GeneratorError on the first non-UTF-8 byte - any binary response
  # (an image, a PDF, a gzip'd payload, protobuf, anything non-text) crashes
  # `complete!` outright. That crash then propagates through
  # Middleware#run_and_store's rescue, which releases the key and re-raises -
  # so the client gets an unhandled exception for a request the app already
  # handled successfully, instead of the real response. Base64-encoding each
  # body chunk before it goes into the JSON document keeps every possible
  # byte value representable regardless of encoding, so storage can't fail
  # on the body's content.
  module ResponseCodec
    module_function

    def dump(response)
      status, headers, body = response
      JSON.generate([status, headers, body.map { |chunk| Base64.strict_encode64(chunk.to_s) }])
    end

    def load(json)
      status, headers, encoded_body = JSON.parse(json)
      [status, headers, encoded_body.map { |chunk| Base64.strict_decode64(chunk) }]
    end
  end
end
