# frozen_string_literal: true

module Wurk
  class Client
    # Pro feature parity: when Redis is unreachable, buffer enqueues
    # in-process and flush on reconnect. Bounded; opt-in via config.
    class Buffered < Client
    end
  end
end
