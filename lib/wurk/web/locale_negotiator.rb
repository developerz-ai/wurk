# frozen_string_literal: true

module Wurk
  class Web
    # Picks the dashboard locale to hint at from a request's `Accept-Language`.
    #
    # The hint is emitted as `#wurk-root[data-locale]` and sits third in the
    # SPA's precedence chain (`?locale=` > stored pick > this > browser
    # preferences), so it only decides the first paint for a visitor who has
    # never chosen — which is what removes the flash of English.
    #
    # Matching mirrors `bundleFor()` in frontend/src/i18n/index.ts rung for
    # rung: exact tag, then the header tag's base subtag, then the first
    # offered locale sharing that base ("pt" -> "pt-BR"). Diverging would emit
    # a hint the SPA then resolves to a different bundle.
    module LocaleNegotiator
      # Quality weight of a single `Accept-Language` entry. Case-insensitive
      # because the parameter name is (RFC 9110 §5.6.6), even though every
      # browser sends a lowercase `q`.
      QUALITY_RE = /;\s*q\s*=\s*([0-9.]+)/i

      module_function

      # The best `offered` locale for `header`, or nil when it asks for none of
      # them. `offered` is host-configured (`Wurk::Web.config.offered_locales`)
      # and the return value is always one of its entries, never header text —
      # that is what keeps request input out of the emitted attribute, and why
      # a malformed tag needs no separate validation: it simply matches nothing.
      def call(header, offered:)
        preferred_tags(header).each do |tag|
          hit = match(tag, offered)
          return hit if hit
        end
        nil
      end

      # Tags in descending quality, ties keeping header order. `q=0` means "not
      # acceptable" and is dropped. `*` is dropped too: a wildcard states no
      # preference, so there is nothing to hint — the host's `default_locale`
      # and the browser's own list already cover that visitor.
      def preferred_tags(header)
        entries = header.to_s.split(',').filter_map { |entry| parse_entry(entry) }
        # sort_by.with_index keeps the sort stable: Ruby's sort_by is not, and
        # equal-quality tags have to stay in the order the client listed them.
        entries.sort_by.with_index { |(_, quality), i| [-quality, i] }.map(&:first)
      end

      def parse_entry(entry)
        tag = entry.split(';').first.to_s.strip
        return if tag.empty? || tag == '*'

        quality = entry[QUALITY_RE, 1]&.to_f || 1.0
        [tag, quality] if quality.positive?
      end

      def match(tag, offered)
        lower = tag.downcase
        base = lower.split('-').first
        offered.find { |loc| loc.downcase == lower } ||
          offered.find { |loc| loc.downcase == base } ||
          offered.find { |loc| loc.downcase.split('-').first == base }
      end

      private_class_method :preferred_tags, :parse_entry, :match
    end
  end
end
