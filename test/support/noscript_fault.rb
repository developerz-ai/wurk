# frozen_string_literal: true

require 'delegate'
require 'digest'
require 'securerandom'

module Wurk
  module Test
    # Puts one round trip through a cold script cache without flushing the real
    # one. The EVALSHA cache is server-wide, so `SCRIPT FLUSH` would hit every
    # parallel worker and any other suite on that Redis; instead, the next
    # direct call or pipeline that carries an EVALSHA has each of its SHAs
    # swapped for one no client ever loaded. The real server then answers
    # NOSCRIPT, at the same point a flushed cache would: inline for a direct
    # call, at finalize for a pipeline, with the pipeline's other commands
    # applied. Later round trips pass through untouched, so the recovery path
    # (SCRIPT LOAD, or a replay through source-embedded EVAL) runs for real.
    #
    # Usage:
    #   Wurk::Test::NoscriptFault.stage(pool) do |fault|
    #     # ... exercise code that runs an EVALSHA through pool ...
    #     assert_predicate fault, :fired?
    #   end
    class NoscriptFault
      # `pool` is the instance the code under test checks out from; its `with`
      # is wrapped for the block and restored after it.
      def self.stage(pool)
        fault = new
        real_with = pool.method(:with)
        pool.define_singleton_method(:with) do |*args, **kwargs, &blk|
          real_with.call(*args, **kwargs) { |conn| blk.call(Tap.new(conn, fault)) }
        end
        yield fault
      ensure
        pool.singleton_class.send(:remove_method, :with) if pool.singleton_class.method_defined?(:with, false)
      end

      attr_reader :hits

      def initialize
        @uncached_sha = Digest::SHA1.hexdigest("wurk-test-never-loaded #{SecureRandom.uuid}")
        @armed = true
        @hits = 0
      end

      # True once a round trip went out with a SHA the server cannot know, so a
      # test can prove it reached the NOSCRIPT path rather than passing vacuously.
      def fired? = @hits.positive?

      def rewrite(args)
        return args unless @armed && args.first.to_s.casecmp?('EVALSHA')

        @hits += 1
        [args.first, @uncached_sha, *args.drop(2)]
      end

      def disarm_if_fired
        @armed = false if fired?
      end

      # The checked-out connection. Each direct call is its own round trip;
      # a pipeline is one, so every EVALSHA it buffers is rewritten before
      # the fault disarms.
      class Tap < SimpleDelegator
        def initialize(conn, fault)
          super(conn)
          @fault = fault
        end

        %i[call call_once].each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            __getobj__.public_send(name, *@fault.rewrite(args), **kwargs, &blk)
          ensure
            @fault.disarm_if_fired
          end
        end

        %i[call_v call_once_v].each do |name|
          define_method(name) do |args, &blk|
            __getobj__.public_send(name, @fault.rewrite(args), &blk)
          ensure
            @fault.disarm_if_fired
          end
        end

        def pipelined(*args, **kwargs, &blk)
          __getobj__.pipelined(*args, **kwargs) { |pipe| blk.call(Pipe.new(pipe, @fault)) }
        ensure
          @fault.disarm_if_fired
        end
      end

      # The buffered pipeline a Tap's `pipelined` yields.
      class Pipe < SimpleDelegator
        def initialize(pipe, fault)
          super(pipe)
          @fault = fault
        end

        %i[call call_once].each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            __getobj__.public_send(name, *@fault.rewrite(args), **kwargs, &blk)
          end
        end

        %i[call_v call_once_v].each do |name|
          define_method(name) { |args, &blk| __getobj__.public_send(name, @fault.rewrite(args), &blk) }
        end
      end
    end
  end
end
