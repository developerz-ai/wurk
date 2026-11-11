# frozen_string_literal: true

module Wurk
  module Metrics
    # Prometheus text format 0.0.4 writers, shared by Metrics::Prometheus and
    # Metrics::ProcessFamilies. Each appends to the String `out`.
    module Exposition
      LABEL_ESCAPES = { '\\' => '\\\\', '"' => '\\"', "\n" => '\\n' }.freeze
      LABEL_ESCAPES_RE = /[\\"\n]/

      private

      def counter(out, name, help, value)
        family(out, name, help, 'counter', [[nil, value]])
      end

      def gauge(out, name, help, samples)
        family(out, name, help, 'gauge', samples)
      end

      def family(out, name, help, type, samples)
        out << "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n"
        samples.each { |labels, value| sample(out, name, labels, value) }
      end

      def sample(out, name, labels, value)
        out << name << label_set(labels) << ' ' << number(value) << "\n"
      end

      def label_set(labels)
        return '' if labels.nil? || labels.empty?

        "{#{labels.map { |k, v| "#{k}=\"#{escape(v)}\"" }.join(',')}}"
      end

      def escape(value)
        value.to_s.gsub(LABEL_ESCAPES_RE, LABEL_ESCAPES)
      end

      def number(value)
        value.is_a?(Float) ? value.round(3).to_s : value.to_i.to_s
      end
    end
  end
end
