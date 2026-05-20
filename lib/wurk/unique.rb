# frozen_string_literal: true

module Wurk
  # Sidekiq Enterprise unique jobs. Three modes:
  # until_executed, until_executing, until_and_while_executing.
  # Implemented as a middleware pair (client + server).
  module Unique
    class ClientMiddleware; end
    class ServerMiddleware; end
  end
end
