# frozen_string_literal: true

require 'json'

module Wurk
  # Display-side argument redaction. A host sets
  #
  #   config.redact_args = ->(job) { [job['args'].first, '[FILTERED]'] }
  #
  # and every surface that SHOWS a job's arguments — the job logger's `args`
  # context (when listed in `logged_job_attributes`) and JobRecord#display_args,
  # which feeds the dashboard JSON, search and the /v1 API — shows the returned
  # array instead. The payload in Redis, and the args
  # `perform` receives, are never touched: the hook gets a deep copy, so even a
  # hook that mutates its argument cannot reach the real job.
  #
  # nil (the default) leaves every surface exactly as it was. The hook runs on
  # encrypted jobs too: Encryption hides only the trailing ciphertext argument,
  # and the plaintext ones before it are what a host usually needs to filter.
  module Redact
    # Fail closed: a hook that raises must not fall back to showing the args it
    # was installed to hide.
    FAILED = ['[REDACTED: redact_args raised]'].freeze

    module_function

    def hook(config = Wurk.configuration)
      config.redact_args
    end

    # The args to display for `job` (a parsed payload Hash) under `hook`.
    def args(job, hook)
      result = hook.call(::JSON.parse(::JSON.generate(job)))
      result.is_a?(Array) ? result : [result]
    rescue StandardError
      FAILED
    end
  end
end
