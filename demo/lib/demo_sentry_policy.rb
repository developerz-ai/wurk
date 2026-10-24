# frozen_string_literal: true

# The public demo's error-reporting policy: the ONE place that decides whether
# the demo reports to Sentry, which events never leave the demo, and what a
# surviving event is allowed to carry.
#
# Plain Ruby on purpose — no Rails, and no Sentry constant at load time — so the
# policy can be exercised without booting the app or loading the SDK
# (test/unit/demo_sentry_test.rb).
#
# Three drop rules, and nothing else:
#
#   1. the demo's intentional failures (BrokenJob, FlakyWebhookJob) — they exist
#      so the Dead and Retries views are never empty;
#   2. a soak-tagged event — a load run marks its events, and their volume says
#      nothing about the demo's health;
#   3. everything else is sent, scrubbed.
#
# Failing closed: an event that cannot be scrubbed is dropped, not sent.

# Wurk's own Sentry integration, for the job-context key below: it never
# loads sentry-ruby, so a demo that is not reporting stays SDK-free.
require 'wurk/sentry'

module DemoSentryPolicy
  # The Sentry context block Wurk's job scope writes. Read from the gem, never
  # copied: a rename there must not silently stop the drop rule from matching.
  JOB_CONTEXT_KEY = Wurk::Sentry::JobContext::CONTEXT_KEY

  # The demo's intentional failures. Reporting them would bury every real error
  # under a steady stream of intended ones.
  INTENTIONAL_FAILURES = %w[BrokenJob FlakyWebhookJob].freeze

  # A header, cookie or argument NAME that is a credential. Matched against the
  # name with its punctuation flattened to spaces, so "X-Api-Key", "api_key" and
  # "Api Key" are one name.
  CREDENTIAL_NAME = /
    \b(?:
      authorization | auth | cookie | api\ key | apikey |
      access\ token | refresh\ token | auth\ token | token |
      secret | password | passwd | private\ key | session |
      credential | bearer | csrf | xsrf
    )\b
  /x

  # A VALUE that is a credential by shape.
  CREDENTIAL_VALUE = Regexp.union(
    /\A\[REDACTED:/i,               # Wurk's own redaction marker
    /\bBearer\s+\S/i,               # "Authorization: Bearer <token>"
    /\beyJ[\w-]+\.[\w-]+\.[\w-]+/, # a JWT
    /\bsk-[\w-]{8,}/,               # an "sk-…" API key
    %r{[A-Za-z0-9_\-/=]{32,}}       # a long opaque run
  )

  # A VALUE that is personal data: an email address.
  PERSONAL_DATA = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/

  module_function

  # --- The gate -----------------------------------------------------------
  #
  # Reporting is on only when the deployment asked for it AND gave us
  # somewhere to report to. The flag alone would boot the SDK with nowhere to
  # send events; the DSN alone would report from a deployment that never
  # opted in.

  def enabled?(env = ENV)
    env_value(env, 'WURK_DEMO_REPORT_ERRORS') == '1' && !dsn(env).to_s.strip.empty?
  end

  def dsn(env = ENV)
    env_value(env, 'SENTRY_DSN')
  end

  # --- The drop rules -----------------------------------------------------

  # Sentry's before_send hook: nil drops the event, anything else is sent.
  def before_send(event, _hint = nil)
    return nil if drop?(event)

    scrub(event)
  rescue StandardError
    # Fail closed: an event we cannot scrub is an event we cannot vouch for.
    nil
  end

  def drop?(event)
    intentional_failure?(event) || soak?(event)
  end

  def intentional_failure?(event)
    klass = job_class(event)

    !klass.nil? && INTENTIONAL_FAILURES.include?(klass)
  end

  # A soak run marks its events with a "soak" tag — as the tag name or as its
  # value.
  def soak?(event)
    tags = field(event, :tags)
    return false unless tags.is_a?(::Hash)

    tags.any? { |key, value| marker?(key) || marker?(value) }
  end

  def marker?(value)
    value.to_s.strip.downcase == 'soak'
  end

  def job_class(event)
    contexts = field(event, :contexts)
    return nil unless contexts.is_a?(::Hash)

    wurk = dig_key(contexts, JOB_CONTEXT_KEY)
    return nil unless wurk.is_a?(::Hash)

    klass = dig_key(wurk, :class)
    klass.is_a?(::String) ? klass : nil
  end

  # --- The scrubbing ------------------------------------------------------

  # Removes credential-shaped material from an event and returns it. The
  # request is scrubbed in place (the SDK owns it); extra and contexts are
  # replaced with scrubbed copies.
  def scrub(event)
    scrub_request(event)
    scrub_extra(event)
    scrub_contexts(event)
    event
  end

  def scrub_request(event)
    request = field(event, :request)
    return unless request

    headers = field(request, :headers)
    request.headers = scrub_map(headers) if headers.is_a?(::Hash) && request.respond_to?(:headers=)

    cookies = field(request, :cookies)
    request.cookies = scrub_map(cookies) if cookies.is_a?(::Hash) && request.respond_to?(:cookies=)
  end

  # Header and cookie maps share one rule: a credential-looking name or a
  # credential-looking value goes.
  def scrub_map(map)
    map.reject { |name, value| credential_name?(name) || credential_value?(value) }
  end

  def scrub_extra(event)
    extra = field(event, :extra)
    return unless extra.is_a?(::Hash)
    return unless event.respond_to?(:extra=)

    out = extra.dup
    job = dig_key(out, :job)
    replace_key(out, :job, scrub_args_container(job)) if job.is_a?(::Hash)
    event.extra = scrub_args_container(out)
  end

  def scrub_contexts(event)
    contexts = field(event, :contexts)
    return unless contexts.is_a?(::Hash)
    return unless event.respond_to?(:contexts=)

    out = contexts.dup
    wurk = dig_key(out, JOB_CONTEXT_KEY)
    replace_key(out, JOB_CONTEXT_KEY, scrub_args_container(wurk)) if wurk.is_a?(::Hash)
    event.contexts = out
  end

  # A container that may hold an "args" list: extra[:job], extra itself, and
  # the Wurk job context block.
  def scrub_args_container(container)
    return container unless container.is_a?(::Hash)

    args = dig_key(container, :args)
    return container unless args.is_a?(::Array)

    out = container.dup
    replace_key(out, :args, scrub_args(args))
    out
  end

  # Job arguments: an argument whose key is a credential, or whose value is a
  # credential or personal data, is removed. Ordinary arguments survive.
  def scrub_args(args)
    args.filter_map do |arg|
      case arg
      when ::Hash then scrub_hash_argument(arg)
      when ::Array then scrub_args(arg)
      when ::String then argument_value?(arg) ? nil : arg
      else arg
      end
    end
  end

  def scrub_hash_argument(argument)
    argument.each_with_object({}) do |(key, value), out|
      next if credential_name?(key) || argument_value?(value)

      out[key] = case value
                 when ::Hash then scrub_hash_argument(value)
                 when ::Array then scrub_args(value)
                 else value
                 end
    end
  end

  # --- The shapes ---------------------------------------------------------

  def credential_name?(name)
    normalized = name.to_s.downcase.gsub(/[^a-z0-9]+/, ' ').strip

    CREDENTIAL_NAME.match?(normalized)
  end

  def credential_value?(value)
    return false unless value.is_a?(::String)

    CREDENTIAL_VALUE.match?(value)
  end

  # An argument may also be personal data — an email address is not a
  # credential, but it is not the demo's to publish either.
  def argument_value?(value)
    return false unless value.is_a?(::String)

    credential_value?(value) || PERSONAL_DATA.match?(value)
  end

  # Every field of a Sentry event is optional, and a malformed event must
  # never take the demo's reporting down.
  def field(object, method)
    object.respond_to?(method) ? object.public_send(method) : nil
  end

  # Hash lookups that do not care whether the key is a Symbol or a String.
  def dig_key(hash, key)
    return nil unless hash.is_a?(::Hash)
    return hash[key] if hash.key?(key)

    string = key.to_s
    hash.key?(string) ? hash[string] : nil
  end

  def replace_key(hash, key, value)
    return hash unless hash.is_a?(::Hash)

    if hash.key?(key)
      hash[key] = value
    else
      string = key.to_s
      hash[string] = value if hash.key?(string)
    end
    hash
  end

  def env_value(env, key)
    return nil unless env.respond_to?(:[])

    value = env[key]
    return value unless value.nil?

    env[key.to_sym] if env.is_a?(::Hash)
  end
end
