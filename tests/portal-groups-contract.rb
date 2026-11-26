# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
module ActionController
  class BadRequest < StandardError; end
end
module ActiveRecord
  class RecordNotFound < StandardError; end
end
require_relative '../zammad-package/lib/wasalx/client'
require_relative '../zammad-package/lib/wasalx/portal_groups'

class PortalGroupsContract < Minitest::Test
  class Gateway
    include Wasalx::PortalGroups
    attr_reader :workspace
    def initialize(workspace)
      @workspace = workspace
    end
    def call(operation, input)
      @envelope = { 'operation' => operation }
      @input = input
      group_operation
    end
    def page(rows, **options)
      group_message_page(rows, **options)
    end
    private
    def group_workspace
      @workspace
    end
    def keys!(allowed)
      raise ArgumentError unless (@input.keys - allowed).empty?
    end
  end

  def fixture_message(id, **attributes)
    { 'id' => id.to_s, 'provider_timestamp' => "2026-10-18T00:00:#{id.to_s.rjust(2, '0')}Z",
      'external_message_id' => "private:#{id}", 'quoted_external_message_id' => nil,
      'participant_name' => 'Customer', 'message_text' => "Message #{id}" }.merge(attributes.transform_keys(&:to_s))
  end

  def test_history_and_context_keep_newest_first_and_truthful_older_cursor
    gateway = Gateway.new(nil)
    rows = [fixture_message(1), fixture_message(3), fixture_message(2)]
    page = gateway.page(rows, limit: 2)
    assert_equal %w[3 2], page[:items].map { |item| item['id'] }
    assert_equal '2', page[:next_cursor]
    assert_nil gateway.page(rows, limit: 3)[:next_cursor]
    assert_equal '1', gateway.page(rows, context: true)[:next_cursor]
  end

  def test_quote_uses_only_one_exact_authorized_source_and_hides_external_identifiers
    gateway = Gateway.new(nil)
    rows = [fixture_message(1), fixture_message(2, quoted_external_message_id: 'private:1'), fixture_message(3, quoted_external_message_id: 'outside-page')]
    page = gateway.page(rows)[:items]
    assert_equal '1', page[1]['quoted_message'][:id]
    assert page[0]['quote_unavailable']
    page.each { |item| refute item.key?('external_message_id'); refute item.key?('quoted_external_message_id') }
    duplicate = gateway.page([rows[0], rows[0].merge('id' => '4'), rows[1]])[:items].find { |item| item['id'] == '2' }
    assert_nil duplicate['quoted_message']
    assert duplicate['quote_unavailable']
  end

  def test_gateway_preserves_request_identity_and_explicit_cancellation_semantics
    workspace = Object.new
    calls = []
    workspace.define_singleton_method(:operation_receipt) { |**input| calls << input; { 'outcome' => 'ADMITTED', 'state' => 'QUEUED', 'terminal' => true } }
    workspace.define_singleton_method(:group_receipt) { |**input| input }
    gateway = Gateway.new(workspace)
    assert_equal({ state: 'ADMITTED', terminal: true },
      gateway.call('GROUP_RECEIPT', { 'group_id' => 'group', 'operation_id' => 'operation', 'kind' => 'REACTION', 'target_message_id' => 'message', 'action' => 'LOOKUP' }))
    assert_equal({ group_id: 'group', request_token: 'operation', kind: 'REACTION', target_message_id: 'message', action: 'LOOKUP' }, calls.last)
    result = gateway.call('GROUP_TICKET_RECEIPT', { 'group_id' => 'group', 'message_id' => 'message', 'operation_id' => 'operation', 'kind' => 'LINK', 'target_ticket_number' => '42', 'action' => 'CANCEL_IF_UNADMITTED' })
    assert_equal 'GROUP_LINK', result[:kind]
    assert_equal 'CANCEL_IF_UNADMITTED', result[:action]
    assert_equal '42', result[:ticket_number]
    assert_raises(ArgumentError) { gateway.call('GROUP_RECEIPT', { 'actor' => 'admin' }) }
    assert_raises(ArgumentError) { gateway.call('GROUP_TICKET_RECEIPT', { 'kind' => 'DELETE' }) }
  end

  def test_mentions_match_the_current_resolved_phone_before_a_private_jid
    workspace = Object.new
    workspace.define_singleton_method(:participants) do |**_input|
      [{ 'id' => '991123456@lid', 'phone' => '+17035550199', 'name' => 'Customer' },
       { 'id' => '16505550127@c.us', 'phone' => nil, 'name' => 'Customer' },
       { 'id' => 'unusable', 'name' => 'Customer' }]
    end
    result = Gateway.new(workspace).call('GROUP_PARTICIPANTS', { 'group_id' => 'group', 'query' => 'Customer' })
    assert_equal %w[17035550199 16505550127], result.map { |item| item['mention_token'] }
    assert_equal '991123456@lid', result.first['id']
  end
end
