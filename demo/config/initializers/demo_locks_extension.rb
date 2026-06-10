# frozen_string_literal: true

# A Sidekiq-style "Locks" Web extension in the exact shape third-party gems use
# (sidekiq-unique-jobs et al.) — `registered(app)` routes, ERB views + locale
# strings + CSS from root_dir/asset_paths, route params, and a POST → redirect
# flow — rendered natively in the dashboard by the extension renderer.
# Registered through the `Sidekiq::Web.register` drop-in alias on purpose: the
# demo proves a Sidekiq extension runs unmodified.
#
# The seeded lock rows double as showcase data; in read-only demo mode the
# Release action 403s, demonstrating the read-only guard on extension routes.
module DemoLocksExt
  ROOT = File.expand_path("../../lib/demo_ext", __dir__)
  KEY = "demo:locks"
  SEED = {
    "3f2a09c1d4e5" => "WelcomeJob",
    "9b81e7aa0c44" => "NightlyExportJob",
    "c57d1f02b9e3" => "SendReceiptJob",
    "71ee5b6d28f0" => "ThrottledApiJob"
  }.freeze

  def self.registered(app)
    app.get "/locks" do
      @locks = DemoLocksExt.seeded_locks
      erb :index
    end

    app.get "/locks/:digest" do
      @digest, @job, @since = DemoLocksExt.lock_detail(route_params(:digest))
      erb :show
    end

    app.post "/locks/:digest/delete" do
      redis { |c| c.call("HDEL", KEY, route_params(:digest)) }
      redirect "locks"
    end
  end

  def self.lock_detail(digest)
    job = Wurk.redis { |c| c.call("HGET", KEY, digest) }
    [digest, job, Time.at(Time.now.to_i - (digest.sum % 3600))]
  end

  def self.seeded_locks
    locks = Wurk.redis { |c| c.call("HGETALL", KEY) }
    return locks unless locks.empty?

    Wurk.redis { |c| c.call("HSET", KEY, *SEED.flatten) }
    SEED.dup
  end
end

Sidekiq::Web.register(
  DemoLocksExt,
  name: "demo_locks",
  tab: ["Locks"],
  index: ["locks/"],
  root_dir: DemoLocksExt::ROOT,
  asset_paths: [File.join(DemoLocksExt::ROOT, "assets")]
)
