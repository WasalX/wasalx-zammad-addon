# SPDX-License-Identifier: AGPL-3.0-only
module Wasalx
# Copyright (c) 2026 WasalX
  module MembershipAccess
    def self.allowed?(user, bound_revision: false, interactive: false, reference: nil, session: nil, auth_type: 'session')
      return !interactive if !user
      return false if ServiceIdentity.automation?(user)
      row = WasalxMembership.find_by(user_id: user.id)
      return bound_revision == false || bound_revision.nil? if !row # Legacy/service accounts.
      return false if bound_revision != false && bound_revision != row.revision
      return false if !user.active || row.member_state != 'ACTIVE' || row.portal_role == 'auditor'
      return false unless MembershipProjection.native_access_matches?(user, row.portal_role, row.member_state)

      result = Client.post('/internal/v1/zammad/membership/check',
        { user_id: row.portal_user_id, native_user_id: user.id.to_s, revision: row.revision }, scope: 'zammad:membership')
      return false unless result.is_a?(Hash) && result['allowed'] == true
      policy = SessionAssurance.policy(result['authentication_policy'])
      return false unless policy && policy['subject'] == row.subject
      return true unless interactive
      SessionAssurance.allowed?(user, row, result, reference: reference, session: session, auth_type: auth_type)
    rescue Client::RequestFailed
      false
    end

    def self.check!(user, **options)
      return if allowed?(user, **options)

      # Tag only our denial while retaining native GraphQL's exception type.
      error = Exceptions::NotAuthorized.new('Workspace access is not available. Sign in with WasalX SSO.')
      error.instance_variable_set(:@wasalx_membership_auth_type, options[:auth_type])
      raise error
    end

    # Native legacy sockets keep a user identity in memory after Sessions.destroy.
    # Missing storage must deny that authenticated socket, not turn it anonymous.
    def self.legacy_allowed?(client_id, session = nil)
      stored_session = Sessions.get(client_id)&.dig(:user)
      stored_id = stored_session && stored_session['id']
      admitted_id = session && session['id']
      return false if admitted_id && stored_id != admitted_id
      reference = stored_session && stored_session[SessionAssurance::REFERENCE]
      return false if session && session[SessionAssurance::REFERENCE] != reference
      user_id = admitted_id || stored_id
      return true unless user_id # Public protocol traffic before authentication.

      # Native legacy events establish/remove their pool inside backend
      # initialization/destruction. These guards also run before initialization
      # and between events, so they must own only the pool they open themselves.
      opened_pool = nil
      begin
        pool = ActiveRecord::Base.connection_pool
      rescue ActiveRecord::ConnectionNotDefined
        pool = opened_pool = ActiveRecord::Base.establish_connection
      end
      pool.with_connection do
        user = User.find_by(id: user_id)
        user && allowed?(user, interactive: true, reference: reference)
      end
    rescue ActiveRecord::ActiveRecordError
      false
    ensure
      if opened_pool
        begin
          ActiveRecord::Base.remove_connection if ActiveRecord::Base.connection_pool.equal?(opened_pool)
        rescue ActiveRecord::ConnectionNotDefined
          # The native caller already removed this pool; never remove another.
        end
      end
    end

    module Authentication
      private
      def authentication_check_only
        super
      rescue Exceptions::NotAuthorized => error
        user_id = session[:user_id]
        raise unless error.instance_variable_get(:@wasalx_membership_auth_type) == 'session' && user_id && defined?(GraphqlController) && is_a?(GraphqlController) && WasalxMembership.find_by(user_id: user_id)

        # Native optional authentication permits guest bootstrap; its schema
        # still rejects every protected field after this own-session reset.
        reset_session
        @_current_user = @_user_on_behalf = @_token = @_token_auth = @_auth_type = nil
        set_user
        false
      end

      def authentication_check_prerequesits(user, auth_type)
        if Wasalx::ServiceIdentity.automation?(user)
          valid = auth_type == 'token_auth' && %w[runtime privacy].any? { |purpose| Wasalx::ServiceIdentity.token_allowed?(user, @_token, purpose) }
          raise Exceptions::NotAuthorized, 'Workspace access is not available' unless valid
        else
          # Native password login reaches this only after Auth#valid!; preserve
          # that path for roles which do not require MFA, never for required roles.
          mode = auth_type == 'session' && is_a?(SessionsController) && action_name == 'create' ? 'native_login' : auth_type
          Wasalx::MembershipAccess.check!(user, interactive: true,
            reference: Wasalx::SessionAssurance.private_id(session), session: session, auth_type: mode)
        end
        super
      end
    end

    module CableConnection
      attr_reader :wasalx_membership_revision, :wasalx_session_reference

      # Native login/config subscriptions have no user. A socket which ever
      # admitted an identity must instead keep its authenticated denial fences.
      def wasalx_public_connection?
        current_user.nil? && !@wasalx_authenticated_connection
      end

      private
      def find_verified_user
        user = super
        @wasalx_authenticated_connection = true if user
        return if user.nil? && !@wasalx_authenticated_connection

        @wasalx_membership_revision = user && WasalxMembership.find_by(user_id: user.id)&.revision
        @wasalx_session_reference = session_id && Rack::Session::SessionId.new(session_id).private_id
        reject_unauthorized_connection unless Wasalx::MembershipAccess.allowed?(user, bound_revision: @wasalx_membership_revision,
          interactive: true, reference: @wasalx_session_reference)
        user
      end
    end

    module CableChannel
      # Public dispatch still uses native schema authorization; it does not
      # authenticate a user or relax protected query/mutation/subscription checks.
      def execute(data)
        return super if current_user.nil? && connection.wasalx_public_connection?

        return connection.close(reconnect: false) unless Wasalx::MembershipAccess.allowed?(current_user, bound_revision: connection.wasalx_membership_revision,
          interactive: true, reference: connection.wasalx_session_reference)
        super
      end
      def transmit(data, **options)
        return super if current_user.nil? && connection.wasalx_public_connection?

        return connection.close(reconnect: false) unless Wasalx::MembershipAccess.allowed?(current_user, bound_revision: connection.wasalx_membership_revision,
          interactive: true, reference: connection.wasalx_session_reference)
        super
      end
    end

    module LegacyEvents
      def run(params)
        return { event: 'error', data: { state: 'no_session' } } unless Wasalx::MembershipAccess.legacy_allowed?(params[:client_id], params[:session])
        super
      end
    end

    module LegacyTransport
      include Wasalx::SessionAssurance::LegacySession
      def send(client_id, data)
        return false unless Wasalx::MembershipAccess.legacy_allowed?(client_id)
        super
      end
      def queue(client_id)
        return [] unless Wasalx::MembershipAccess.legacy_allowed?(client_id)
        super
      end
    end

    module LegacyDirectTransport
      def websocket_send(client_id, data)
        client = @clients[client_id]
        unless Wasalx::MembershipAccess.legacy_allowed?(client_id, client && client[:session])
          if client
            client[:disconnect] = true
            @clients.delete(client_id)
            client[:websocket].close_websocket
          end
          return
        end
        super
      end
    end

    module OidcCreation
      def create_from_hash(hash, user = nil)
        return super unless hash['provider'] == 'openid_connect'
        Authorization.transaction do
          Authorization.connection.execute('SELECT pg_advisory_xact_lock(742831650)')
          readiness = Wasalx::Client.post('/internal/v1/zammad/membership/identity', { subject: hash['uid'] }, scope: 'zammad:membership')
          raise Authorization::Provider::AccountError unless readiness.is_a?(Hash) && [true, false].include?(readiness['enabled'])
          if readiness['enabled'] == true
            # Accepted identities are provisioned before native first login. Do not
            # create a second Customer while adoption or synchronization is pending.
            auth = Authorization.find_by(provider: 'openid_connect', uid: hash['uid'])
            raise Authorization::Provider::AccountError unless auth && auth.user_id.to_s == readiness['native_user_id'] && (!user || user.id == auth.user_id)
            next auth
          end
          # Default-off legacy creation is unchanged, but shares the projection lock
          # so a concurrent first login cannot race an exact-subject adoption.
          existing = Authorization.find_by(provider: 'openid_connect', uid: hash['uid'])
          raise Authorization::Provider::AccountError if existing && user && existing.user_id != user.id
          existing || super
        end
      rescue Wasalx::Client::RequestFailed
        raise Authorization::Provider::AccountError
      end
    end
  end
end
