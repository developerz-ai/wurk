# Encryption

A drop-in for `Sidekiq::Enterprise::Crypto`. It encrypts the **last** positional argument of a job with AES-256-GCM — the client middleware seals it on push, the server middleware opens it before `perform`. Earlier args stay plaintext so you can still triage on `user_id`.

```ruby
# config/initializers/wurk.rb — point at any key source (file, ENV, KMS)
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  File.binread("config/crypto/secret.#{Rails.env}.#{version}.key") # exactly 32 bytes
end
```

```ruby
class ChargeCardJob
  include Sidekiq::Job
  sidekiq_options encrypt: true

  def perform(user_id, secret_bag) # secret_bag arrives already decrypted
    Payments.charge(user_id, secret_bag["pan"], secret_bag["cvv"])
  end
end
```

## Key rotation (zero downtime)

Keep every still-in-flight version resolvable so old jobs decrypt, then bump `active_version`:

```ruby
KEYS = {
  1 => File.binread("config/crypto/secret.production.1.key"),
  2 => File.binread("config/crypto/secret.production.2.key"),
}

# Step 1: ship the new key + resolver that knows both, active still 1.
Sidekiq::Enterprise::Crypto.enable(active_version: 1) { |v| KEYS.fetch(v) }
# Step 2: once every process has the new key, bump active_version → 2.
Sidekiq::Enterprise::Crypto.enable(active_version: 2) { |v| KEYS.fetch(v) }
```

## Graceful failure

A job that can't be decrypted (key rotated away, corrupt ciphertext) goes **straight to the dead set in under a second** rather than crash-looping through 25 retries, with the still-encrypted payload preserved for replay. The dashboard renders encrypted args as `"<encrypted>"`; cleartext is never written to Redis.
