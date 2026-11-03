# frozen_string_literal: true

# Test-only. The gem's middleware_test asserts that upstream's private
# Processor#process re-raises the job's exception, killing and replacing the thread.
# Wurk books the failure and returns. No production code can observe the difference.
class Wurk::Processor # rubocop:disable Style/ClassAndModuleChildren
  prepend(Module.new do
    def report_job_failure(handled, job_hash)
      Thread.current[:ecosystem_job_error] = handled.cause || handled
      super
    end

    def process(uow)
      Thread.current[:ecosystem_job_error] = nil
      super
      error = Thread.current[:ecosystem_job_error]
      raise error if error
    end
  end)
end
