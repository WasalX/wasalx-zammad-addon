# SPDX-License-Identifier: AGPL-3.0-only
# Committed, isolated two-connection race; no source or runtime credential is printed.
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'securerandom'
require 'timeout'
require Rails.root.join('lib/wasalx/portal_service_identity')
raise 'Isolated simulated native fixture required' unless ENV['WASALX_TEST_ISOLATED'] == '1' && ENV['WASALX_NATIVE_DIAGNOSTIC'] == 'true'
record = Wasalx::ServiceIdentity.receipt
owner = WasalxMembership.find_by!(portal_user_id: ENV.fetch('WASALX_ADMIN_TEST_OWNER'))
raise 'Foreign service owner race fixture' unless record && record['human_native_user_id'] == owner.user_id.to_s
runtime = Token.find(record['runtime_token_id']); privacy = Token.find(record['privacy_token_id'])
proof = { 'configured_runtime_sha256' => Digest::SHA256.hexdigest(runtime.token), 'configured_privacy_sha256' => Digest::SHA256.hexdigest(privacy.token) }
operations = [SecureRandom.uuid, SecureRandom.uuid]
team = nil; threads = []; release = nil
invoke = lambda do |kind, input, after_lock = nil|
  human = User.find(owner.user_id)
  envelope = { 'tenant_id' => owner.tenant_id, 'instance_id' => owner.instance_id,
    'actor' => { 'user_id' => owner.portal_user_id, 'revision' => owner.revision, 'native_user_id' => human.id.to_s,
      'subject' => owner.subject, 'email' => owner.email }, 'operation' => kind, 'input' => proof.merge(input) }
  UserInfo.with_user_id(human.id) do
    Wasalx::PortalServiceIdentity.new(actor: human, token: runtime, envelope: envelope,
      authorizer: -> { after_lock&.call; human.reload }).call
  end
end
begin
  team = Group.create!(name: "Service race #{SecureRandom.hex(6)}", active: true, created_by_id: owner.user_id, updated_by_id: owner.user_id)
  [true, false].each_with_index do |cancel_wins, index|
    id = operations[index]
    machine = User.find(record['automation_native_user_id'])
    # Obtain the actual saved-grant CAS token without duplicating its digest recipe.
    probe = Wasalx::PortalServiceIdentity.new(actor: owner.user, token: runtime, envelope: {
      'actor' => { 'user_id' => owner.portal_user_id }, 'operation' => 'IDENTITY_STATUS', 'input' => {} }, authorizer: -> { owner.user })
    probe.instance_variable_set(:@record, record)
    grant = { 'request_id' => id, 'team_id' => team.id.to_s, 'expected_version' => probe.send(:grant_version, team), 'enabled' => true }
    cancel = { 'request_id' => id.upcase, 'kind' => 'IDENTITY_GRANT', 'team_id' => team.id.to_s, 'action' => 'CANCEL_IF_UNADMITTED' }
    held, ready, release = Queue.new, Queue.new, Queue.new
    first_kind, first_input = cancel_wins ? ['IDENTITY_RECEIPT', cancel] : ['IDENTITY_GRANT', grant]
    second_kind, second_input = cancel_wins ? ['IDENTITY_GRANT', grant] : ['IDENTITY_RECEIPT', cancel]
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '10s'")
        begin
          invoke.call(first_kind, first_input, -> { held << connection.select_value('SELECT pg_backend_pid()'); release.pop })
        ensure
          connection.execute('RESET lock_timeout')
        end
      end
    end
    threads << first
    first_pid = Timeout.timeout(10) { held.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '10s'")
        ready << connection.select_value('SELECT pg_backend_pid()')
        begin
          invoke.call(second_kind, second_input)
        rescue Wasalx::PortalServiceIdentity::Conflict
          :conflict
        ensure
          connection.execute('RESET lock_timeout')
        end
      end
    end
    threads << second
    second_pid = Timeout.timeout(10) { ready.pop }
    raise 'Race used one native DB connection' if first_pid == second_pid
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event FROM pg_stat_activity WHERE pid=#{Integer(second_pid)}")
        break if waiting == 'advisory'
        sleep 0.01
      end
    end
    release << true
    outcomes = Timeout.timeout(20) { [first.value, second.value] }
    row = WasalxAdminOperation.find_by!(operation_id: id)
    accesses = UserGroup.where(user_id: machine.id, group_id: team.id).pluck(:access)
    if cancel_wins
      raise 'Delayed write crossed cancellation' unless row.result['state'] == 'NOT_APPLIED' && outcomes[1] == :conflict && accesses.empty?
    else
      raise 'Late cancellation erased admitted effect' unless row.result['state'] == 'APPLIED' && outcomes[1]['state'] == 'APPLIED' && accesses == ['full']
    end
    raise 'Duplicate action receipts' unless WasalxAdminOperation.where(operation_id: id).count == 1
  end
ensure
  original_failure = $!
  release << true if release
  join_failure = nil
  threads.each do |thread|
    begin
      thread.join
    rescue StandardError => failure
      join_failure ||= failure
    end
  end
  UserInfo.with_user_id(owner.user_id) do
    Transaction.execute do
      UserGroup.where(user_id: record['automation_native_user_id'], group_id: team.id).destroy_all if team
      WasalxAdminOperation.where(operation_id: operations).destroy_all
      team&.reload&.destroy!
    end
  end
  raise join_failure if !original_failure && join_failure
end
puts 'Service identity two-connection cancellation race passed; committed fixture cleaned.'
