# frozen_string_literal: true

module Wurk
  # `Process.pid` is a real syscall on Linux — glibc dropped its getpid cache in
  # 2.25 — and the fetch+execute path reads it twice per job ({Component.tid}
  # and the fetcher's per-queue key cache, both of which read it only to notice
  # a fork). Measured at ~640ns a call against ~110ns for this memo, which is
  # about 1% of a job's CPU spent asking the kernel a question whose answer
  # changes at most once in a process's life.
  #
  # Refreshed in the child half of every fork, so a swarm child never answers
  # with the pid it inherited — the whole reason those two call sites read it.
  #
  # Same shape as redis-client's PIDCache, deliberately not borrowed from it:
  # that is a private constant of a dependency, and this one is on our hot path.
  module PidCache
    if ::Process.respond_to?(:fork)
      class << self
        attr_reader :pid

        def update!
          @pid = ::Process.pid
        end
      end
      update!

      # Prepended, not aliased: `Process._fork` is a documented hook (Ruby 3.1+,
      # and Wurk requires 3.2) that several gems wrap, and prepending composes
      # with theirs instead of replacing it.
      module CoreExt
        def _fork
          child_pid = super
          PidCache.update! if child_pid.zero?
          child_pid
        end
      end
      ::Process.singleton_class.prepend(CoreExt)
    else # JRuby / TruffleRuby / Windows — no fork, so nothing can invalidate it
      @pid = ::Process.pid
      singleton_class.attr_reader(:pid)
    end
  end
end
