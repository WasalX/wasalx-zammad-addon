# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'minitest/autorun'
require 'uri'

module ActiveRecord
  class RecordNotFound < StandardError; end
  class RecordInvalid < StandardError; end
end
module Exceptions
  class Forbidden < StandardError; end
  class ApplicationModel < StandardError; end
end
module ActionController
  class BadRequest < StandardError; end
end
class Object
  def __(text); text; end
  def blank?; respond_to?(:empty?) ? empty? : !self; end
  def present?; !blank?; end
end
module UserInfo
  class << self; attr_accessor :current_user_id; end
end
class Hash
  def to_query; URI.encode_www_form(self); end
end
class Ticket
  Record = Struct.new(:id) { def reload; self; end }
  def self.find(id); raise ActiveRecord::RecordNotFound unless id.to_s == '42'; Record.new(42); end
  class Article
    Record = Struct.new(:id, :ticket_id, :body) do
      def reload; raise 'Per-record article reload is forbidden'; end
      def association(name)
        raise 'Unexpected association' unless name == :ticket
        @ticket ||= Struct.new(:target).new
      end
    end
    class << self; attr_accessor :queries, :records; end
    def self.where(ticket_id:, id:)
      self.queries += 1
      values = records || id.map { |value| Record.new(value.to_i, ticket_id, 'Current body') }
      values.select { |row| row.ticket_id == ticket_id && id.include?(row.id.to_s) }.map(&:dup)
    end
  end
end
class TicketPolicy
  class << self; attr_accessor :allowed; end
  def initialize(*); end
  def agent_read_access?; self.class.allowed; end
end
class Ticket::ArticlePolicy
  class << self; attr_accessor :allowed, :calls; end
  def initialize(*); end
  def show?; self.class.calls += 1; self.class.allowed; end
end
class User
  Actor = Struct.new(:id, :active, :groups, :permissions) do
    def permissions?(name); permissions.include?(name); end
    def group_ids_access(_access); groups; end
    def fullname; 'Synthetic operator'; end
  end
  class << self; attr_accessor :record; end
  def self.find(id)
    raise 'Unexpected native user' unless record.id == id
    record
  end
end
module Wasalx
  module ServiceIdentity
    def self.automation?(actor); actor.permissions?('wasalx_service'); end
  end
  module MembershipAccess
    class << self; attr_accessor :allowed; end
    def self.check!(_actor); raise Exceptions::Forbidden unless allowed; end
  end
  class Client
    class RequestFailed < StandardError
      attr_reader :http_status
      def initialize(message = nil, http_status: nil); super(message); @http_status = http_status; end
    end
    class TemporaryRequestFailed < RequestFailed; end
    class PermanentRequestFailed < RequestFailed; end
    class << self; attr_accessor :calls, :result, :on_get, :error; end
    def self.get(path, scope:, actor:)
      calls << [path, scope, actor]
      on_get&.call
      raise error if error
      result || { 'items' => [] }
    end
    def self.post(path, payload, scope:, actor:)
      calls << [path, payload, scope, actor]
      { 'state' => 'QUEUED' }
    end
  end
end
require_relative '../zammad-package/lib/wasalx/group_workspace'

class GroupWorkspaceServiceContract < Minitest::Test
  GROUP = '12000000-0000-4000-8000-000000000001'
  MESSAGE = '13000000-0000-4000-8000-000000000001'
  REQUEST = '14000000-0000-4000-8000-000000000001'

  def setup
    User.record = User::Actor.new(41, true, [7], ['ticket.agent'])
    Wasalx::MembershipAccess.allowed = true
    Wasalx::Client.calls = []
    Wasalx::Client.result = nil; Wasalx::Client.on_get = nil; Wasalx::Client.error = nil
    Ticket::Article.queries = 0; Ticket::Article.records = nil
    TicketPolicy.allowed = true; Ticket::ArticlePolicy.allowed = true; Ticket::ArticlePolicy.calls = 0
    UserInfo.current_user_id = 99
    @workspace = Wasalx::GroupWorkspace.new(actor: User.record)
  end

  def test_source_lookup_batches_exact_native_articles_and_rechecks_access_after_control
    ids = (1..20).map(&:to_s)
    value = { 'article_id' => '20', 'group_id' => GROUP, 'message_id' => MESSAGE }
    Wasalx::Client.result = { 'items' => [value], 'truncated' => false }
    assert_equal [value], @workspace.ticket_sources(ticket_id: '42', article_ids: ids)
    assert_equal 1, Wasalx::Client.calls.length
    assert_equal 2, Ticket::Article.queries, "One native article batch per authorization pass, independent of page size"
    assert_equal 40, Ticket::ArticlePolicy.calls, "Each current article retains native policy on both passes"
    path, scope, actor = Wasalx::Client.calls.last
    assert_equal '/internal/v1/zammad/group-workspace/tickets/42/message-context', URI.parse(path).path
    assert_equal ids.join(','), URI.decode_www_form(URI.parse(path).query).to_h['article_ids']
    assert_equal 'zammad:groups', scope
    assert_equal 41, actor[:user_id]
    Wasalx::Client.on_get = -> { Ticket::ArticlePolicy.allowed = false }
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['20']) }
  end

  def test_source_lookup_never_trusts_an_article_hint_or_incomplete_or_cross_article_response
    TicketPolicy.allowed = false
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
    assert_empty Wasalx::Client.calls
    TicketPolicy.allowed = true
    assert_raises(ActionController::BadRequest) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1', '1']) }
    assert_raises(ActionController::BadRequest) { @workspace.ticket_sources(ticket_id: '42', article_ids: (1..21).map(&:to_s)) }
    Wasalx::Client.result = { 'items' => [{ 'article_id' => '2', 'group_id' => GROUP, 'message_id' => MESSAGE }], 'truncated' => false }
    assert_raises(ArgumentError) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
    Wasalx::Client.result = { 'items' => [], 'truncated' => true }
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
    Wasalx::Client.result = { 'items' => [], 'truncated' => false }
    assert_empty @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'])
    Wasalx::Client.on_get = -> { Wasalx::MembershipAccess.allowed = false }
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
  end

  def test_optional_source_outage_or_truncation_yields_fresh_articles_without_claiming_absence
    row = Ticket::Article::Record.new(1, 42, 'Before mapping')
    Ticket::Article.records = [row]
    Wasalx::Client.on_get = -> { row.body = 'After mapping' }
    Wasalx::Client.error = Wasalx::Client::TemporaryRequestFailed.new('Synthetic mapping-only outage')
    fresh = nil
    assert_nil @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) { |values| fresh = values }
    assert_equal 'After mapping', fresh.first.body
    assert_equal 42, fresh.first.association(:ticket).target.id
    assert_equal 2, Ticket::Article.queries
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
    Wasalx::Client.error = nil
    Wasalx::Client.result = { 'items' => [], 'truncated' => true }
    assert_nil @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true)
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1']) }
  end

  def test_optional_source_outage_never_swallows_current_native_membership_or_article_denial
    Wasalx::Client.error = Wasalx::Client::TemporaryRequestFailed.new('Synthetic mapping-only outage')
    Wasalx::Client.on_get = -> { Wasalx::MembershipAccess.allowed = false }
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) }
    Wasalx::MembershipAccess.allowed = true
    Wasalx::Client.on_get = -> { Ticket::ArticlePolicy.allowed = false }
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) }
    Ticket::ArticlePolicy.allowed = true
    row = Ticket::Article::Record.new(1, 42, 'Current body')
    Ticket::Article.records = [row]
    Wasalx::Client.on_get = -> { row.ticket_id = 43 }
    assert_raises(Exceptions::Forbidden) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) }
  end

  def test_optional_sources_do_not_soften_control_denials_or_invalid_response_bindings
    [400, 401, 403, 404, 409].each do |status|
      Wasalx::Client.error = Wasalx::Client::PermanentRequestFailed.new('Synthetic control denial', http_status: status)
      assert_raises(Wasalx::Client::PermanentRequestFailed) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) }
    end
    Wasalx::Client.error = nil
    Wasalx::Client.result = { 'items' => [{ 'article_id' => '2', 'group_id' => GROUP, 'message_id' => MESSAGE }], 'truncated' => false }
    assert_raises(ArgumentError) { @workspace.ticket_sources(ticket_id: '42', article_ids: ['1'], optional: true) }
  end

  def test_context_uses_verified_human_grants_without_changing_machine_context
    @workspace.context(group_id: GROUP, message_id: MESSAGE)
    assert_equal ["/internal/v1/zammad/group-workspace/groups/#{GROUP}/messages/#{MESSAGE}/context",
      'zammad:groups', { user_id: 41, group_ids: [7], group_admin: false }], Wasalx::Client.calls.last
    assert_equal 99, UserInfo.current_user_id
  end

  def test_revoked_or_machine_actor_cannot_read_group_content
    Wasalx::MembershipAccess.allowed = false
    assert_raises(Exceptions::Forbidden) { @workspace.context(group_id: GROUP, message_id: MESSAGE) }
    Wasalx::MembershipAccess.allowed = true
    User.record.permissions << 'wasalx_service'
    assert_raises(Exceptions::Forbidden) { @workspace.context(group_id: GROUP, message_id: MESSAGE) }
    assert_empty Wasalx::Client.calls
  end

  def test_read_acknowledgement_remains_actor_attributed_write
    @workspace.read(group_id: GROUP, message_id: MESSAGE)
    path, payload, scope, actor = Wasalx::Client.calls.last
    assert_equal "/internal/v1/zammad/group-workspace/groups/#{GROUP}/read", path
    assert_equal({ messageId: MESSAGE }, payload)
    assert_equal 'zammad:groups', scope
    assert_equal 41, actor[:user_id]
  end

  def test_text_send_preserves_durable_key_quote_and_author
    @workspace.send_message(group_id: GROUP, request_token: REQUEST, message: "  Hello\r\nteam  ",
      reply_to_message_id: MESSAGE, mentions: [])
    _path, payload, scope, actor = Wasalx::Client.calls.last
    assert_equal "Hello\nteam", payload[:message]
    assert_equal MESSAGE, payload[:replyToMessageId]
    assert_equal 'Synthetic operator', payload[:agentDisplayName]
    assert_equal "group-workspace:41:#{REQUEST}", payload[:idempotency_key]
    assert_equal [], payload[:attachments]
    assert_equal 'zammad:groups', scope
    assert_equal 41, actor[:user_id]
    assert_equal 99, UserInfo.current_user_id
  end
  def test_operation_receipt_keeps_exact_scope_and_distinguishes_lookup_from_explicit_cancellation
    %w[SEND REACTION].each do |kind|
      %w[LOOKUP CANCEL_IF_UNADMITTED].each do |action|
        @workspace.operation_receipt(group_id: GROUP, kind: kind, request_token: REQUEST,
          target_message_id: kind == 'REACTION' ? MESSAGE : nil, action: action)
        path, payload, scope, actor = Wasalx::Client.calls.last
        assert_equal "/internal/v1/zammad/group-workspace/groups/#{GROUP}/operation-receipt", path
        assert_equal({ kind: kind, requestId: REQUEST, action: action,
          targetMessageId: kind == 'REACTION' ? MESSAGE : nil }.compact, payload)
        assert_equal 'zammad:groups', scope
        assert_equal({ user_id: 41, group_ids: [7], group_admin: false }, actor)
      end
    end
    assert_equal 99, UserInfo.current_user_id
  end

  def test_receipt_identifiers_are_not_authority_and_invalid_requests_never_dispatch
    Wasalx::MembershipAccess.allowed = false
    assert_raises(Exceptions::Forbidden) { @workspace.operation_receipt(group_id: GROUP, kind: 'SEND', request_token: REQUEST) }
    Wasalx::MembershipAccess.allowed = true
    [{ kind: 'SEND', request_token: 'bad' }, { kind: 'OTHER', request_token: REQUEST },
     { kind: 'REACTION', request_token: REQUEST }, { kind: 'SEND', request_token: REQUEST, target_message_id: MESSAGE },
     { kind: 'SEND', request_token: REQUEST, action: 'CANCEL' }].each do |input|
      assert_raises(ActionController::BadRequest) { @workspace.operation_receipt(group_id: GROUP, **input) }
    end
    assert_empty Wasalx::Client.calls
  end

end
