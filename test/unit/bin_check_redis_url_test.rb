# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'socket'
require 'tmpdir'

# bin/check's Redis guard must look where the suite will connect: REDIS_URL,
# which lib/wurk and test_helper already read, falling back to the default.
# A box whose Redis is not on 127.0.0.1:6379 (the developerz.ai fleet moves its
# sidecar off the well-known port so a repo's own store can bind it) must not
# be refused for a server the suite was never going to use.
#
# Drives the real script in `fast` mode with a stub `bundle` on PATH, so every
# stage past the guard is a no-op and the exit code is the guard's verdict.
class BinCheckRedisUrlTest < Minitest::Test
  parallelize_me!

  CHECK = File.expand_path('../../bin/check', __dir__)

  def run_check(redis_url)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, 'bundle')
      File.write(stub, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, stub)
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'REDIS_URL' => redis_url }
      Open3.capture3(env, CHECK, 'fast')
    end
  end

  def closed_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def test_refuses_when_the_redis_url_server_is_down_and_names_it
    port = closed_port
    _out, err, status = run_check("redis://127.0.0.1:#{port}/0")

    assert_equal 75, status.exitstatus, err
    assert_includes err, "127.0.0.1:#{port}"
  end

  def test_runs_the_gate_when_the_redis_url_server_answers
    server = TCPServer.new('127.0.0.1', 0)
    begin
      _out, err, status = run_check("redis://127.0.0.1:#{server.addr[1]}/3")

      assert_equal 0, status.exitstatus, err
    ensure
      server.close
    end
  end
end
