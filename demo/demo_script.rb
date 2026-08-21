
# frozen_string_literal: true

# Drives the exact scenario recorded in demo/idempotent-rack-demo.cast, so
# the recording is reproducible (re-run it, or re-record it) rather than a
# one-off transcript nobody can regenerate. Zero gems, zero Rails - a plain
# Rack env built by hand, same pattern test/test_helper.rb uses.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "idempotent_rack"
require "json"
require "stringio"

def rack_env(method: "POST", path: "/charges", body: "", headers: {})
  env = {
    "REQUEST_METHOD" => method,
    "PATH_INFO" => path,
    "rack.input" => StringIO.new(body),
  }
  headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
  env
end

charge_app = lambda do |env|
  body = env["rack.input"].read
  puts "  [app executing for real] body=#{body.inspect}"
  [201, { "Content-Type" => "application/json" }, [JSON.generate({ "charge_id" => "ch_599", "amount" => 4200 })]]
end

mw = IdempotentRack::Middleware.new(charge_app)

def show(status, headers, body)
  puts "  -> status=#{status} replayed=#{headers['Idempotency-Replayed'].inspect} body=#{body.first}"
end

puts "First request:"
show(*mw.call(rack_env(body: '{"amount":4200}', headers: { "Idempotency-Key" => "req_a1b2c3" })))

puts "Client retries with the SAME key (e.g. connection dropped, naive retry):"
show(*mw.call(rack_env(body: '{"amount":4200}', headers: { "Idempotency-Key" => "req_a1b2c3" })))

puts "A different request reuses the key with a DIFFERENT body:"
show(*mw.call(rack_env(body: '{"amount":9999}', headers: { "Idempotency-Key" => "req_a1b2c3" })))

puts "Two concurrent requests with a NEW key, racing each other:"
slow_app = lambda do |env|
  env["rack.input"].read
  sleep 0.2
  [201, { "Content-Type" => "application/json" }, [JSON.generate({ "charge_id" => "ch_race" })]]
end
race_mw = IdempotentRack::Middleware.new(slow_app)
statuses = []
mutex = Mutex.new
t1 = Thread.new do
  status, = race_mw.call(rack_env(body: '{"amount":100}', headers: { "Idempotency-Key" => "req_race1" }))
  mutex.synchronize { statuses << status }
end
sleep 0.05 # let the first thread actually claim the key before the second fires
status2, = race_mw.call(rack_env(body: '{"amount":100}', headers: { "Idempotency-Key" => "req_race1" }))
mutex.synchronize { statuses << status2 }
t1.join
puts "  -> statuses seen: #{statuses.sort} (one 201, one 409 - only one execution wins the claim)"
