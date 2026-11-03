# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'uri'

module Wurk
  module Test
    # Two suite runs whose DBs overlap FLUSHDB each other mid-test, and that reads as
    # a random integration failure: a job counter that comes back empty, a 240s wait
    # for jobs that are gone. WURK_TEST_DB_OFFSET is coordinated by hand, so nothing
    # stopped it. Each DB a run uses is now held by an flock for the run's lifetime,
    # and an overlap refuses to start. A forked child would share that flock and keep it
    # past the run if it leaked, naming a dead holder, so children drop their copy; the
    # run's own parent holds it until it exits, however it exits.
    #
    # Covers runs on one machine sharing one server, which is the case that exists;
    # a server shared across machines is not detected.
    module RedisDbLock
      class Held < StandardError; end

      # A suite spawned from inside a suite belongs to the outer run's DBs.
      OWNER_ENV = 'WURK_TEST_DB_LOCK_OWNER'

      class << self
        def acquire!(databases, url: ENV.fetch('REDIS_URL'), dir: default_dir)
          return [] if ENV.key?(OWNER_ENV)

          held = []
          files = databases.map do |database|
            file = open_lock(dir, url, database)
            if file.flock(File::LOCK_EX | File::LOCK_NB)
              record_holder(file)
            else
              held << [database, holder(file)]
            end
            file
          end
          raise Held, refusal(held, databases, url) unless held.empty?

          ENV[OWNER_ENV] = ::Process.pid.to_s
          # Kept open on purpose: closing a file releases its flock.
          @files = files
        end

        # Serializes a test class that needs a fixed DB every run shares, across runs.
        def with_dedicated(database, url: ENV.fetch('REDIS_URL'), dir: default_dir)
          file = open_lock(dir, url, database)
          file.flock(File::LOCK_EX)
          (@dedicated ||= []) << file
          yield
        ensure
          @dedicated&.delete(file)
          file&.close
        end

        # Called in a fork child, where closing drops only the child's reference.
        def drop_inherited
          [*@files, *@dedicated].each(&:close)
          @files = @dedicated = nil
        end

        def default_dir = File.join(Dir.tmpdir, "wurk-test-db-locks-#{::Process.uid}")

        private

        def open_lock(dir, url, database)
          FileUtils.mkdir_p(dir)
          uri = URI.parse(url)
          File.open(File.join(dir, "#{uri.host}-#{uri.port}-#{database}.lock"), File::RDWR | File::CREAT)
        end

        def record_holder(file)
          file.truncate(0)
          file.rewind
          file.write("pid #{::Process.pid} in #{Dir.pwd}")
          file.flush
        end

        def holder(file)
          file.rewind
          text = file.read.to_s.strip
          text.empty? ? 'another test run' : text
        end

        def refusal(held, databases, url)
          lines = held.map { |database, by| "  DB #{database}: #{by}" }
          first = databases.min

          <<~MESSAGE
            test Redis DBs #{databases.minmax.uniq.join('..')} on #{URI.parse(url).host} overlap a run still going:
            #{lines.join("\n")}
            Two runs on one DB FLUSHDB each other, which shows up as random integration failures.
            Set WURK_TEST_DB_OFFSET so this run's DBs (offset + 1 up to offset + NCPU) are free
            (it was #{first - 1}), or wait for that run to finish.
          MESSAGE
        end
      end
    end

    # Every fork in Ruby goes through this, whoever asks for it.
    module DropLocksInForks
      def _fork
        pid = super
        RedisDbLock.drop_inherited if pid.zero?
        pid
      end
    end
    ::Process.singleton_class.prepend(DropLocksInForks)

    # A separate DB keeps keys apart but not CPU, and it is the loaded box that makes
    # wall-clock integration tests fail. So a run says when it did not have the server
    # to itself, next to any failures it reports. Everything here is best effort.
    module RedisNeighbours
      class << self
        # Its own short-lived client, so nothing opened here crosses a fork. On the run's
        # own DB, never DB 0.
        def count(url = ENV.fetch('REDIS_URL'))
          client = RedisClient.config(url: url, timeout: 1).new_client
          [client.call('CLIENT', 'LIST').to_s.lines.size - 1, 0].max
        rescue StandardError
          0
        ensure
          client&.close
        end

        def note(at_start, at_end)
          peak = [at_start, at_end].max
          return if peak.zero?

          "note: up to #{peak} other connection(s) shared this Redis server during this run. " \
            'If a wall-clock integration test failed, re-run it on an idle box before debugging it.'
        end
      end
    end
  end
end
