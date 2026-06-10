# frozen_string_literal: true

# Demo Web extension (WURK_DEMO=1): a Sidekiq-style "Locks" tab in the shape
# real gems use (sidekiq-unique-jobs et al.) — `registered(app)` routes, ERB
# views + locale strings + CSS from root_dir/asset_paths, route params, and a
# POST → redirect flow — all rendered natively by the #187 extension renderer.
# Registered through the `Sidekiq::Web.register` drop-in alias on purpose.
if ENV['WURK_DEMO'] == '1'
  module DemoLocksExt
    ROOT = File.expand_path('../../lib/demo_ext', __dir__)
    KEY = 'demo:locks'
    SEED = {
      '3f2a09c1d4e5' => 'WelcomeEmailJob',
      '9b81e7aa0c44' => 'NightlyReportJob',
      'c57d1f02b9e3' => 'SyncInventoryJob',
      '71ee5b6d28f0' => 'ChargeSubscriptionJob'
    }.freeze

    def self.registered(app)
      app.get '/locks' do
        @locks = DemoLocksExt.seeded_locks
        erb :index
      end

      app.get '/locks/:digest' do
        @digest, @job, @since = DemoLocksExt.lock_detail(route_params(:digest))
        erb :show
      end

      app.post '/locks/:digest/delete' do
        redis { |c| c.call('HDEL', KEY, route_params(:digest)) }
        redirect 'locks'
      end
    end

    def self.lock_detail(digest)
      job = Wurk.redis { |c| c.call('HGET', KEY, digest) }
      [digest, job, Time.at(Time.now.to_i - (digest.sum % 3600))]
    end

    def self.seeded_locks
      locks = Wurk.redis { |c| c.call('HGETALL', KEY) }
      return locks unless locks.empty?

      Wurk.redis { |c| c.call('HSET', KEY, *SEED.flatten) }
      SEED.dup
    end
  end

  Sidekiq::Web.register(
    DemoLocksExt,
    name: 'demo_locks',
    tab: ['Demo Locks'],
    index: ['locks/'],
    root_dir: DemoLocksExt::ROOT,
    asset_paths: [File.join(DemoLocksExt::ROOT, 'assets')]
  )
end
