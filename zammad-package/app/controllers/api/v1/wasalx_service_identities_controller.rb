# SPDX-License-Identifier: AGPL-3.0-only
require_relative '../../../../lib/wasalx/portal_service_identity'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

class Api::V1::WasalxServiceIdentitiesController < Api::V1::WasalxPortalWorkspaceController
  def create
    Wasalx::ServiceIdentity.authorize!(current_user, @_token)
    @envelope = Wasalx::PortalDelegation.decode_identity(request.raw_post, request.headers['X-Wasalx-Timestamp'].to_s,
      request.headers['X-Wasalx-Signature'].to_s, secret: ENV.fetch('WASALX_SERVICE_JWT_SECRET'),
      tenant: ENV.fetch('WASALX_TENANT_ID'), instance: ENV.fetch('WASALX_ZAMMAD_INSTANCE_ID'))
    actor = identity_actor!
    result = UserInfo.with_user_id(actor.id) do
      Wasalx::PortalServiceIdentity.new(actor: actor, token: @_token, envelope: @envelope, authorizer: -> { identity_actor! }, bootstrap_projection: -> { @bootstrap_projection }).call
    end
    response.headers['Cache-Control'] = 'private, no-store'
    render json: result
  rescue ReauthenticationRequired
    render json: { code: 'REAUTHENTICATION_REQUIRED' }, status: :forbidden
  rescue Wasalx::PortalDelegation::Invalid, ArgumentError
    render json: { code: 'INVALID_WORKSPACE_REQUEST' }, status: :bad_request
  rescue Wasalx::ServiceIdentity::Conflict, Wasalx::PortalServiceIdentity::Conflict
    render json: { code: 'WORKSPACE_CONFLICT' }, status: :conflict
  rescue Wasalx::Client::RequestFailed, Wasalx::PortalServiceIdentity::StorageError
    render json: { code: 'WORKSPACE_UNAVAILABLE' }, status: :service_unavailable
  end

  private

  def bootstrap_actor!
    operation = @envelope['operation']
    raise Exceptions::Forbidden unless %w[IDENTITY_STATUS IDENTITY_INITIALIZE IDENTITY_RECEIPT].include?(operation)
    if operation == 'IDENTITY_RECEIPT'
      raise Exceptions::Forbidden unless @envelope['input']['kind'] == 'IDENTITY_INITIALIZE'
    end
    identity = @envelope['actor']
    bound = Authorization.where(provider: 'openid_connect', uid: identity['subject']).to_a
    raise Exceptions::Forbidden unless bound.one?
    actor = bound.first.user
    record = Wasalx::ServiceIdentity.receipt
    managed = WasalxMembership.find_by(user_id: actor.id)
    exact = record ? record['origin'] == 'OWNER_CONVERSION' && record['human_native_user_id'] == actor.id.to_s &&
      record['human_subject'] == identity['subject'] && record['human_email'] == identity['email'] && managed &&
      managed.portal_user_id == identity['user_id'] && managed.subject == identity['subject'] && managed.email == identity['email'] &&
      managed.revision == identity['revision'] && managed.tenant_id == @envelope['tenant_id'] && managed.instance_id == @envelope['instance_id'] : actor.id == current_user.id
    raise Exceptions::Forbidden unless exact && actor.active && actor.email == identity['email'] &&
      actor.permissions?('admin.group') && actor.permissions?('admin.user') && !Wasalx::ServiceIdentity.automation?(actor)
    result = Wasalx::Client.post('/internal/v1/zammad/membership/bootstrap-check',
      { user_id: identity['user_id'], native_user_id: actor.id.to_s, revision: identity['revision'],
        subject: identity['subject'], email: identity['email'] }, scope: 'zammad:membership')
    policy = result.is_a?(Hash) && Wasalx::SessionAssurance.policy(result['authentication_policy'])
    assurance = @envelope.fetch('assurance')
    raise Exceptions::Forbidden unless result.is_a?(Hash) && result['allowed'] == true && policy &&
      policy['subject'] == identity['subject'] && result['portal_source'] == @envelope['source'] &&
      Wasalx::SessionAssurance.recent?(assurance['auth_time'], policy) && Wasalx::SessionAssurance.authoritative_mfa?(assurance, policy)
    privileged = operation == 'IDENTITY_INITIALIZE' || operation == 'IDENTITY_RECEIPT' && @envelope['input']['action'] == 'CANCEL_IF_UNADMITTED'
    if privileged
      minutes = result['privileged_reauth_minutes']
      raise ReauthenticationRequired unless minutes.is_a?(Integer) && (5..120).cover?(minutes) && Time.now.to_i - assurance['auth_time'] <= minutes * 60
    end
    @bootstrap_projection = result.fetch('projection')
    actor
  end

  def identity_actor!
    return bootstrap_actor! if @envelope['actor']['native_user_id'].nil?
    actor = resolve_actor!
    row = WasalxMembership.find_by!(user_id: actor.id)
    raise Exceptions::Forbidden unless row.portal_role == 'tenant_owner'
    privileged = Wasalx::PortalServiceIdentity::WRITES.include?(@envelope['operation']) ||
      @envelope['operation'] == 'IDENTITY_RECEIPT' && @envelope['input']['action'] == 'CANCEL_IF_UNADMITTED'
    return actor unless privileged
    result = Wasalx::Client.post('/internal/v1/zammad/membership/check',
      { user_id: row.portal_user_id, native_user_id: actor.id.to_s, revision: row.revision, privileged: true }, scope: 'zammad:membership')
    policy = result.is_a?(Hash) && Wasalx::SessionAssurance.policy(result['authentication_policy'])
    assurance = @envelope.fetch('assurance'); minutes = result.is_a?(Hash) && result['privileged_reauth_minutes']
    raise Exceptions::Forbidden unless result.is_a?(Hash) && result['allowed'] == true && policy &&
      policy['subject'] == row.subject && result['portal_source'] == @envelope['source'] &&
      minutes.is_a?(Integer) && (5..120).cover?(minutes) && Wasalx::SessionAssurance.authoritative_mfa?(assurance, policy)
    raise ReauthenticationRequired unless Wasalx::SessionAssurance.recent?(assurance['auth_time'], policy) &&
      Time.now.to_i - assurance['auth_time'] <= minutes * 60
    actor
  end
end
