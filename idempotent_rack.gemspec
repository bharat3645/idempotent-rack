require_relative "lib/idempotent_rack/version"

Gem::Specification.new do |spec|
  spec.name = "idempotent_rack"
  spec.version = IdempotentRack::VERSION
  spec.authors = ["Bharat Singh Parihar"]
  spec.email = ["145659423+bharat3645@users.noreply.github.com"]

  spec.summary = "Idempotency-Key middleware for Rack and Rails APIs"
  spec.description = "Rack middleware that dedupes retried POST/PUT/PATCH requests against " \
                     "an Idempotency-Key header: the first request runs and its response is " \
                     "cached, a retry with the same key replays that response instead of " \
                     "re-running the request, a concurrent duplicate gets 409, and reusing a " \
                     "key with different request parameters gets 422. Zero runtime dependencies."
  spec.homepage = "https://github.com/bharat3645/idempotent-rack"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
