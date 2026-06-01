# frozen_string_literal: true

# A unique job (Enterprise parity): only one SendReceipt for a given order may
# be in flight per window. Re-enqueues within the window are dropped, so the
# producer can fire it repeatedly and the Limiters/uniqueness behavior is visible.
class SendReceiptJob
  include Sidekiq::Job

  sidekiq_options unique_for: 30

  def perform(_order_id)
    sleep(rand * 0.05)
  end
end
