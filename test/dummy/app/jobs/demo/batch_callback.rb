# frozen_string_literal: true

module Demo
  # Batch callback target. Wurk invokes `new.on_<event>(status, options)` when a
  # batch reaches the registered event (see Wurk::Batch::CallbackJob), so the
  # Batches widget shows batches that actually fired success/complete callbacks.
  class BatchCallback
    def on_success(_status, _options); end

    def on_complete(_status, _options); end
  end
end
