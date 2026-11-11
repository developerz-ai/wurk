# frozen_string_literal: true

module Wurk
  module Lua
    # Pro Fast API (§11) deletes, `Queue#delete_job` and `#delete_by_class`: a
    # cursor walk over the queue list from the head, one `fast_delete_window`
    # call per WINDOW entries. The scripts this replaced copied the whole list
    # into the Lua heap and LREMed per match, holding Redis for the entire
    # queue (~300ms per call at 100k jobs).
    #
    # Each call is atomic and removes only payloads it matched, so nothing that
    # did not match is ever deleted. Between calls the list moves:
    #   * pops from the tail (every fetcher: LMOVE/BLMOVE RIGHT, BRPOP) shift no
    #     head index, so they cannot make the walk skip an entry;
    #   * pushes at the head (LPUSH, every enqueue) shift entries already
    #     visited forward, into a window still to come: they are read again,
    #     which re-checks a non-match and costs nothing else;
    #   * the walk's own removals are subtracted from the cursor.
    # What can make it miss a match is another removal ahead of the cursor
    # between calls (a concurrent delete on the same queue, an LREM or LPOP
    # by another client): the entries shift back past the cursor. Such a
    # match stays in the queue and a second call finds it; nothing extra is
    # ever removed.
    module FastDelete
      WINDOW = 1000
      # Matches one call rewrites before it hands the cursor on: each is an
      # LSET that walks the list to its index (see fast_delete_window.lua).
      MAX_REMOVED_PER_CALL = 100

      # No JSON payload starts with a NUL byte.
      TOMBSTONE = "\0wurk-fast-delete\0"

      module_function

      # [payloads removed, first removed payload or nil].
      def call(conn, key, needle, window: WINDOW, max_removed: MAX_REMOVED_PER_CALL)
        cursor = 0
        removed = 0
        first = nil
        loop do
          argv = [needle, cursor, window, TOMBSTONE, max_removed]
          cursor, count, payload = Loader.eval_cached(conn, :fast_delete_window, keys: [key], argv: argv)
          removed += count
          first ||= payload
          return [removed, first] if cursor.negative?
        end
      end

      def delete_job(conn, key, jid)
        call(conn, key, %("jid":"#{jid}")).last
      end

      def delete_by_class(conn, key, klass)
        call(conn, key, %("class":"#{klass}")).first
      end
    end
  end
end
