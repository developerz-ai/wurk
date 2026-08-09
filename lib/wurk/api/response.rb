# frozen_string_literal: true

require 'json'

module Wurk
  module API
    # Success bodies for the HTTP API; Problem is the error half. One owner per
    # content type the API emits, so a route table never spells out a header for
    # itself and the two halves can't drift on the ones they share.
    module Response
      CONTENT_TYPE = 'application/json'

      # nosniff for Problem's reason: a body that echoes what the client sent
      # must never be talked into rendering as anything but data.
      HEADERS = { 'content-type' => CONTENT_TYPE, 'x-content-type-options' => 'nosniff' }.freeze

      module_function

      # Dups the headers because a Rack middleware downstream is entitled to
      # add to them, and the frozen literal is shared by every response.
      #
      # @return [Array(Integer, Hash, Array<String>)] Rack response triple.
      def json(status, payload)
        [status, HEADERS.dup, [::JSON.generate(payload)]]
      end
    end
  end
end
