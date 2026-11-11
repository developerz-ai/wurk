# frozen_string_literal: true

# The app `wurk api -r` loads for tests/test_end_to_end.py: one admin token,
# and any class may be enqueued, since no worker runs these jobs.
require 'wurk'

Wurk.configuration.api_token(ENV.fetch('WURK_E2E_TOKEN'), scopes: %i[admin])
Wurk.configuration.api_enqueue_classes = :any
