# frozen_string_literal: true

# Batch callback target — Wurk calls `new.on_<event>(status, options)` when the
# export batch completes/succeeds, so the Batches page shows fired callbacks.
class ExportCallback
  def on_success(_status, _options); end
  def on_complete(_status, _options); end
end
