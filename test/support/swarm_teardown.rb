# frozen_string_literal: true

require 'English'

# Cleanup for the `Thread.new { swarm.supervise }` pattern every real-fork
# integration test uses. `Wurk::Swarm#shutdown` never joins the supervise loop
# and `Thread#kill` is asynchronous, so a plain `join(t) || kill` can return
# while the supervisor is still parked in `Process.wait(-1, …)` — where it
# steals the exit status of the *next* test's children.
module SwarmTeardown
  KILL_GRACE = 5

  def stop_supervisor_thread(supervisor, timeout)
    return if supervisor.nil?
    return if supervisor.join(timeout)

    supervisor.kill
    return if supervisor.join(KILL_GRACE)

    message = "supervisor thread survived shutdown + kill + #{KILL_GRACE}s join; " \
              'it is still reaping children and will corrupt later tests'
    # Called from an `ensure`: $ERROR_INFO is the exception already on its way
    # out, and replacing a real assertion failure with this one hides the cause.
    raise message if $ERROR_INFO.nil?

    warn message
  end
end
