# frozen_string_literal: true

require_relative "idempotent_rack/version"
require_relative "idempotent_rack/store"
require_relative "idempotent_rack/file_store"
require_relative "idempotent_rack/middleware"

# Note: idempotent_rack/store_contract is intentionally NOT required here.
# It is a Minitest helper for store authors (it defines test methods, not
# runtime code), so requiring it would pull test concerns into the runtime
# load path. Store authors require it explicitly from their own test suite.

module IdempotentRack
end
