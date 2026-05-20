# frozen_string_literal: true

module Wurk
  # Sidekiq Enterprise rate limiters: concurrent, window, bucket, unlimited.
  # Spec: docs/target/sidekiq-ent.md.
  module Limiter
    class Concurrent; end
    class Window; end
    class Bucket; end
    class Unlimited; end

    class << self
      def concurrent(name, **opts); end
      def window(name, **opts); end
      def bucket(name, **opts); end
      def unlimited(name); end
    end
  end
end
