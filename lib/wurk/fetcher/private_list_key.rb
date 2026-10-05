# frozen_string_literal: true

require_relative '../keys'

module Wurk
  class Fetcher
    # Reads the owner back out of a reliable-fetch private list key
    # (`queue:<public>|<host>|<pid>|<nonce>|<idx>`, see
    # Reliable.private_queue_name) for the Reaper's liveness check. Pure string
    # work, no Redis.
    module PrivateListKey
      module_function

      # `queue:<public>|<host>|<pid>|<nonce>|<idx>` → [public_q, host, pid,
      # nonce], parsed from the right so a `|` inside the queue name is
      # tolerated. nil when the key isn't a well-formed private list.
      #
      # With no known prefix to split on, both owner shapes are tried in
      # preference order and the first one leaving a real public queue behind
      # wins. The narrow reading is what saves a pre-nonce key from an all-digit
      # host (`queue:q|123456789012|<pid>|<idx>` — a bare Docker hostname is 12
      # hex chars): read wide, its host segment eats the whole queue name.
      def parse_full(key)
        parts = key.split('|')
        owner_tails(parts).each do |host, pid, nonce, width|
          public_q = parts[0...-width].join('|')
          next unless public_q.start_with?(Keys::QUEUE_PREFIX) && public_q != Keys::QUEUE_PREFIX

          return [public_q, host, pid, nonce]
        end
        nil
      end

      # `<public_q>|<host>|<pid>|<nonce>|<idx>` → [host, pid, nonce] (pid as
      # Integer), or all-nil when the suffix isn't a well-formed owner tail.
      # Splitting the suffix off the known public-queue prefix tolerates a `|`
      # inside the queue name itself, and leaves the tail unambiguous: exactly
      # 4 segments for the current shape, exactly 3 for the pre-nonce one.
      def parse_owner(public_q, key)
        suffix = key.delete_prefix("#{public_q}|")
        return [nil, nil, nil] if suffix == key

        host, pid, nonce = owner_tails(suffix.split('|')).first
        [host, pid, nonce]
      end

      # Owner segments of a private-list key, taken from the right, as
      # [host, pid, nonce, segment_count] readings in preference order (empty
      # when nothing parses). The wide shape is preferred: an all-digit nonce is
      # rare but reachable, and reading such a key narrow would take the pid for
      # the host and the nonce for the pid — draining a live owner's list out
      # from under it.
      def owner_tails(parts)
        return [] unless parts.size >= 3 && integer?(parts[-1])

        [wide_tail(parts), narrow_tail(parts)].compact
      end

      # `<host>|<pid>|<nonce>|<idx>` — the shape every current process writes.
      def wide_tail(parts)
        [parts[-4], parts[-3].to_i, parts[-2], 4] if parts.size >= 4 && integer?(parts[-3])
      end

      # `<host>|<pid>|<idx>` — written before the nonce existed. Such a list can
      # still hold a pre-upgrade process's in-flight jobs across a rolling
      # upgrade, so it stays reclaimable even though nothing writes it anymore.
      def narrow_tail(parts)
        [parts[-3], parts[-2].to_i, nil, 3] if integer?(parts[-2])
      end

      def integer?(str)
        str.is_a?(String) && str.match?(/\A\d+\z/)
      end
    end
  end
end
