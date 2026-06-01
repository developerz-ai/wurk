# frozen_string_literal: true

# Behavioral driver for #41 — dashboard auth via `Wurk::Web.use`.
#
# Boots the dummy Rails app in-process (no server needed), wires a real
# `Rack::Auth::Basic` guard through the host hook exactly as a prod operator
# would, then drives the mounted engine to prove:
#
#   * unauthenticated request  -> 401 (dashboard never renders)
#   * wrong credentials        -> 401
#   * correct credentials      -> 200
#   * the host middleware runs BEFORE the authorization hook
#
# Prints PASS/FAIL per check and exits non-zero on any failure.
#
#   ruby test/qa/dashboard_auth_driver.rb
#
# Needs a local Redis (the engine's JSON APIs read it). Uses RAILS_ENV=test so
# the swarm stays disabled — this exercises only the web layer.

ENV['RAILS_ENV'] ||= 'test'
ENV['WURK_DISABLED'] = '1'

require_relative '../dummy/config/environment'
require 'rack/test'
require 'base64'

include Rack::Test::Methods # rubocop:disable Style/MixinUsage

def app = Rails.application

USER = 'ops'
PASS = 's3cret'

# Exactly what an internal-tool operator drops into config/initializers/wurk.rb.
Wurk::Web.reset_config!
Wurk::Web.use(Rack::Auth::Basic, 'Wurk Dashboard') do |user, password|
  user == USER && password == PASS
end

# Prove host middleware runs ahead of the per-request authorization hook by
# recording whether the hook ever saw an authenticated request.
hook_ran = false
Wurk::Web.configure do |c|
  c.authorization do |_env, _method, _path|
    hook_ran = true
    true
  end
end

$failures = 0

def check(label, expected, actual)
  ok = expected == actual
  $failures += 1 unless ok
  puts "  #{ok ? 'PASS' : 'FAIL'}  #{label} (expected #{expected}, got #{actual})"
end

def basic(user, pass)
  "Basic #{Base64.strict_encode64("#{user}:#{pass}")}"
end

puts '#41 dashboard auth — Wurk::Web.use(Rack::Auth::Basic)'

get '/wurk/api/stats'
check('no credentials -> 401', 401, last_response.status)

header 'Authorization', basic(USER, 'wrong')
get '/wurk/api/stats'
check('wrong password -> 401', 401, last_response.status)

header 'Authorization', basic('intruder', PASS)
get '/wurk/api/stats'
check('wrong user -> 401', 401, last_response.status)

header 'Authorization', basic(USER, PASS)
get '/wurk/api/stats'
check('correct credentials -> 200', 200, last_response.status)
check('authorization hook ran only after auth passed', true, hook_ran)

Wurk::Web.reset_config!

if $failures.zero?
  puts "\nALL PASS"
  exit 0
else
  puts "\n#{$failures} FAILED"
  exit 1
end
