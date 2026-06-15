# Seed a handful of demo job profiles so the Profiles page has content to show.
# Uses the real Wurk::Profiler.store path (same wire schema the worker writes).
require 'securerandom'
require 'json'

samples = [
  ['Demo::ReportJob',       15_200, 4],
  ['Demo::FastJob',            120, 11],
  ['Demo::RateLimitedJob',     890, 23],
  ['Demo::BatchChildJob',    3_400, 47],
  ['ThrottledApiJob',          540, 95],
  ['Demo::SlowReportJob',    7_600, 140],
  ['MailerJob',                250, 320],
]

now = Time.now.to_i
samples.each do |type, ms, mins_ago|
  frames = Array.new((ms / 40) + 8) { |n| { name: "#{type}#run##{n}", line: n + 1 } }
  gecko = {
    meta: { interval: 1, startTime: 0, product: type },
    threads: [{ name: 'main', funcTable: frames, samples: { length: frames.size } }],
  }.to_json
  Wurk::Profiler.store(
    jid: SecureRandom.hex(12),
    type: type,
    gecko_json: gecko,
    started_at: now - (mins_ago * 60),
    elapsed_ms: ms,
  )
end

puts "seeded #{samples.size} demo profiles"
