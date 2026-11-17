# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

module Wasalx
  # Guard native whole-hash saves against another request's auth transition.
  # No pending values are merged or restored, and no lock spans provider I/O.
  module SessionState
    SNAPSHOTS = 'wasalx.native_auth_snapshots'.freeze
    DENIED = 'wasalx.native_auth_write_denied'.freeze
    KEYS = %w[omniauth.state omniauth.nonce omniauth.pkce.verifier omniauth.params omniauth.origin
              user_id authentication_type switched_from_user_id _csrf_token oidc_id_token oidc_sid
              wasalx_oidc_assurance wasalx_native_authentication wasalx_oidc_recovery].freeze
    LIMIT = 65_536
    class Conflict < StandardError
      def initialize; super('Native sign-in changed; start sign-in again'); end
    end

    def self.rows
      ActionDispatch::Session::ActiveRecordStore.session_class
    end

    def self.reference(sid)
      value = sid&.private_id
      raise Conflict unless SessionAssurance.text?(value, 512)
      value
    end

    def self.context(data)
      raise Conflict unless data.is_a?(Hash)
      selected = KEYS.each_with_object({}) { |key, result| result[key] = data[key] if data.key?(key) }
      serialized = Marshal.dump(selected)
      raise Conflict if serialized.bytesize > LIMIT
      Digest::SHA256.hexdigest(serialized)
    end

    def self.remember(env, sid, data, record, replace: false)
      reference = reference(sid)
      snapshots = env[SNAPSHOTS] ||= {}
      raise Conflict unless record && record.id && record.session_id == reference && (snapshots.key?(reference) || snapshots.length < 4)
      snapshot = { id: record.id, context: context(data) }
      snapshots[reference] = snapshot if replace || !snapshots.key?(reference)
    rescue StandardError
      env[DENIED] = true
      raise Conflict, cause: nil
    end

    def self.with_current(env, sid, request: nil)
      raise Conflict if env[DENIED]
      reference = reference(sid)
      quiet do
        rows.transaction do
          record = rows.uncached { rows.lock.find_by(session_id: reference) }
          expected = env.dig(SNAPSHOTS, reference)
          if !expected && request && record
            # Rack can renew/drop before forcing a lazy session load. Load only
            # this still-existing locked generation; never a missing-row fallback.
            lazy = request.env['rack.session']
            raise Conflict unless lazy && !lazy.loaded?
            lazy.send(:load!)
            expected = env.dig(SNAPSHOTS, reference)
          end
          raise Conflict unless expected && record && record.id == expected[:id] && context(record.data) == expected[:context]
          yield record
        end
      end
    rescue StandardError
      env[DENIED] = true
      raise Conflict, cause: nil
    end

    def self.stage!(env, session)
      durable!(env)
      data = session.to_hash
      context(data)
      sid = session.id
      with_current(env, sid) do |record|
        record.data = data
        record.save!
        remember(env, sid, record.data, record, replace: true)
      end
    rescue StandardError
      env[DENIED] = true
      raise Conflict, cause: nil
    end

    def self.consume(env, session, submitted)
      durable!(env)
      session.to_hash # Native id alone need not materialize this request's snapshot.
      raise Conflict unless SessionAssurance.text?(submitted, 1_024)
      sid = session.id
      with_current(env, sid) do |record|
        stored = record.data['omniauth.state']
        raise Conflict unless stored.is_a?(String) && stored == submitted
        # Core still consumes/verifies its original local nonce and PKCE values.
        # Only this exact persisted state is consumed before any provider POST.
        record.data = record.data.dup
        record.data.delete('omniauth.state')
        record.save!
        remember(env, sid, record.data, record, replace: true)
        stored
      end
    rescue StandardError
      env[DENIED] = true
      nil
    end

    def self.durable!(env)
      raise Conflict if rows.connection.transaction_open?
    rescue StandardError
      env[DENIED] = true
      raise Conflict, cause: nil
    end

    def self.quiet
      # Match native ActiveRecordStore: session SQL must not expose auth data.
      logger = rows.logger
      logger ? logger.silence { yield } : yield
    end

    module Store
      private
      def find_session(request, id)
        raise Wasalx::SessionState::Conflict if request.env[Wasalx::SessionState::DENIED]
        sid, data = super
        Wasalx::SessionState.remember(request.env, sid, data, request.env[self.class::SESSION_RECORD_KEY])
        [sid, data]
      end

      def write_session(request, sid, data, options)
        Wasalx::SessionState.with_current(request.env, sid) do |record|
          saved = super
          raise Wasalx::SessionState::Conflict unless saved && saved.private_id == sid.private_id
          Wasalx::SessionState.remember(request.env, sid, data, record, replace: true)
          saved
        end
      rescue Wasalx::SessionState::Conflict
        # Returning a SID here would let the outer refresh wrapper enroll an
        # unrelated pending grant despite the rejected native session save.
        false
      end

      def delete_session(request, sid, options)
        Wasalx::SessionState.with_current(request.env, sid, request: request) do
          generated = super
          if options[:renew] && generated
            record = request.env[self.class::SESSION_RECORD_KEY]
            Wasalx::SessionState.remember(request.env, generated, record.data, record)
          end
          generated
        end
      rescue Wasalx::SessionState::Conflict
        request.env[Wasalx::SessionState::DENIED] = true
        raise
      end
    end

    module Oidc
      def request_phase
        Wasalx::SessionState.durable!(env)
        result = super
        Wasalx::SessionState.stage!(env, session)
        result
      end

      def callback_phase
        Wasalx::SessionState.durable!(env)
        if options.send_state && (!params['state'].is_a?(String) || params['state'].empty?)
          env[Wasalx::SessionState::DENIED] = true
        end
        super
      end

      private
      def stored_state
        state = Wasalx::SessionState.consume(env, session, params['state'])
        session.delete('omniauth.state')
        state
      end
    end
  end
end
