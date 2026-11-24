# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

require 'json'
require 'logger'
require 'minitest/autorun'
require 'stringio'

ROOT = File.expand_path('..', __dir__)
TENANT_ID = '10000000-0000-4000-8000-000000000001'
INSTANCE_ID = '11000000-0000-4000-8000-000000000001'
ROUTE_ID = '51000000-0000-4000-8000-000000000001'

module ActiveSupport
  module Concern
    def included(base = nil, &block)
      return super(base) if base

      @wasalx_included_block = block
    end
  end
end

class Setting
  class << self
    attr_accessor :import_mode

    def get(name)
      name == 'import_mode' ? import_mode : nil
    end
  end
end

class Locale
  class << self
    attr_accessor :default
  end
end

module PoParser
  Entry = Struct.new(:msgid, :msgstr) do
    def translated? = !msgstr.empty?
  end

  def self.parse_file(path)
    entries = File.read(path, encoding: 'UTF-8').scan(/^msgid (".*")\r?\nmsgstr (".*")$/).map do |id, text|
      Entry.new(JSON.parse(id), JSON.parse(text))
    end
    Struct.new(:entries).new(entries)
  end
end

# Existing contract fixtures represent legacy, unmanaged native accounts.
class WasalxMembership
  def self.find_by(user_id:)
    nil
  end
end

class ApplicationJob
  attr_accessor :arguments, :logger
  attr_reader :retry_wait

  class << self
    attr_accessor :enqueue_after_transaction_commit, :log_arguments
    attr_reader :retry_contract

    def retry_on(error, attempts:, wait:, &exhausted)
      @retry_contract = { error: error, attempts: attempts, wait: wait, exhausted: exhausted }
    end

    def perform_later(*arguments)
      enqueued_jobs << arguments
    end

    def enqueued_jobs
      @enqueued_jobs ||= []
    end

    def reset_jobs!
      @enqueued_jobs = []
    end
  end

  def job_id
    'b13edf7f-838b-4409-b57b-d661a101c8ed'
  end

  def perform_attempt(payload, attempt)
    self.arguments = [payload]
    perform(payload)
  rescue self.class.retry_contract.fetch(:error) => error
    contract = self.class.retry_contract
    if contract[:attempts] == :unlimited || attempt < contract[:attempts]
      @retry_wait = contract.fetch(:wait).call(attempt)
    elsif contract[:exhausted]
      contract[:exhausted].call(self, error)
    else
      raise
    end
  end
end

module Transaction
  class << self
    attr_accessor :calls, :after_execute, :depth

    def execute(options = {})
      calls << options
      previous_depth = depth.to_i
      self.depth = previous_depth + 1
      result = yield
      after_execute&.call
      result
    ensure
      self.depth = previous_depth
    end
  end
end

class Object
  def presence
    respond_to?(:empty?) && empty? ? nil : self
  end

  def present?
    !respond_to?(:empty?) || !empty?
  end
end


class NilClass
  def present?
    false
  end
end

class FalseClass
  def present?
    false
  end
end

module Mail
  class Address
    attr_reader :address

    def initialize(value)
      match = value.match(/(?:\A|<)([^<>\s]+@[^<>\s]+)(?:>|\z)/)
      raise ArgumentError, 'invalid email' if match.nil?

      @address = match[1]
    end
  end
end

class FixedTimeZone
  def now
    Time.utc(2026, 8, 9, 12, 0, 0)
  end
end

Time.define_singleton_method(:zone) { @wasalx_test_zone ||= FixedTimeZone.new }

class Ticket
  class << self
    attr_accessor :records

    def find(id)
      records.fetch(id)
    end

    def find_by(id:)
      records[id]
    end
  end
end

class Ticket::State
  Record = Struct.new(:id, :name, :state_type_id)
  RECORDS = {
    2 => Record.new(2, 'open', 2),
    4 => Record.new(4, 'closed', 5)
  }.freeze

  def self.lookup(id:)
    RECORDS[id]
  end
end

class Ticket::StateType
  Record = Struct.new(:id, :name)
  RECORDS = {
    2 => Record.new(2, 'open'),
    5 => Record.new(5, 'closed')
  }.freeze

  def self.lookup(id:)
    RECORDS[id]
  end
end

class Ticket::Article
  class << self
    attr_accessor :records, :created_notes

    def find(id)
      records.fetch(id)
    end

    def find_by(id: nil, ticket_id: nil, message_id: nil)
      if id
        article = records[id]
        return article if article && (ticket_id.nil? || article.ticket_id == ticket_id)
        return nil
      end
      records.values.find { |article| article.ticket_id == ticket_id && article.message_id == message_id }
    end

    def where(**attributes)
      matches = records.values.select { |article| attributes.all? { |key, value| article.public_send(key) == value } }
      Object.new.tap { |relation| relation.define_singleton_method(:find_each) { matches.each } }
    end

    def create!(attributes)
      created_notes << attributes
      attributes
    end
  end
end

class Ticket::Article::Sender
  Record = Struct.new(:name)
  RECORDS = {
    1 => Record.new('Agent'),
    2 => Record.new('Customer'),
    3 => Record.new('System')
  }.freeze

  def self.lookup(id:)
    RECORDS[id]
  end

  def self.find_by(name:)
    RECORDS.values.find { |record| record.name == name }
  end
end

class Ticket::Article::Type
  Record = Struct.new(:name)
  RECORDS = {
    10 => Record.new('wasalx group message'),
    11 => Record.new('note'),
    12 => Record.new('email')
  }.freeze

  def self.lookup(id:)
    RECORDS[id]
  end

  def self.find_by(name:)
    RECORDS.values.find { |record| record.name == name }
  end
end

module Service
  class Base
    def self.execute(**arguments)
      new(**arguments).execute
    end

    def __(value)
      value
    end
  end

  module Ticket
    module Article
      module Type
        module WasalxGroupMessage; end
      end
    end
  end
end

load File.join(ROOT, 'zammad-package/lib/wasalx/client.rb')
load File.join(ROOT, 'zammad-package/lib/wasalx/routing_configuration.rb')

class Wasalx::Client
  class << self
    attr_accessor :response, :error
    attr_reader :calls

    alias_method :http_post, :post

    def get(path, scope:, actor: nil)
      @calls << { path: path, scope: scope, actor: actor }
      raise error if error

      response
    end

    def post(path, payload, scope:, actor: nil)
      @calls ||= []
      @calls << { path: path, payload: payload, scope: scope, actor: actor }
      raise error if error

      response.respond_to?(:call) ? response.call(path, payload) : response
    end

    def reset_test_state!
      @calls = []
      @response = { 'id' => 'delivery-1', 'state' => 'QUEUED' }
      @error = nil
    end
  end
end

load File.join(ROOT, 'zammad-package/app/services/service/ticket/wasalx_reply_context.rb')
load File.join(ROOT, 'zammad-package/app/services/service/ticket/article/type/wasalx_group_message/deliver.rb')
load File.join(ROOT, 'zammad-package/app/jobs/communicate_wasalx_job.rb')
load File.join(ROOT, 'zammad-package/app/models/ticket/article/enqueue_communicate_wasalx_job.rb')
load File.join(ROOT, 'zammad-package/app/jobs/wasalx_ticket_state_job.rb')
load File.join(ROOT, 'zammad-package/app/jobs/wasalx_ticket_routing_job.rb')
load File.join(ROOT, 'zammad-package/app/models/ticket/enqueue_wasalx_ticket_state_job.rb')

FakeUser = Struct.new(:firstname, :lastname, :read_group_ids, :group_admin) do
  def group_ids_access(permission)
    raise ArgumentError, 'unsupported group permission' if permission != 'read'

    read_group_ids || [4, 9]
  end

  def permissions?(permission)
    permission == 'ticket.agent' || permission.start_with?('ticket.agent.') ||
      (group_admin == true && permission == 'admin')
  end
end
FakeAttachment = Struct.new(:id, :filename, :size, :preferences)

class FakeTicket
  attr_reader :id, :updates
  attr_accessor :wasalx_connection_id, :wasalx_group_id, :wasalx_reference,
                :wasalx_latest_external_message_id, :wasalx_client_routing_version_id,
                :wasalx_client_id, :wasalx_client_route_status, :wasalx_client_route_matched_by,
                :wasalx_assignment_revision, :wasalx_bot_state,
                :group_id, :owner_id, :number

  def initialize(id: 42)
    @id = id
    @wasalx_connection_id = 'connection-1'
    @wasalx_group_id = 'test-user-1675@example.test'
    @wasalx_reference = 'ABC1234567'
    @wasalx_latest_external_message_id = 'message-previous'
    @updates = []
    @group_id = 1
    @owner_id = 2
    @wasalx_assignment_revision = 0
    @number = '10042'
  end

  def update!(attributes)
    assignment_changed = (attributes.key?(:group_id) && attributes[:group_id] != group_id) ||
      (attributes.key?(:owner_id) && attributes[:owner_id] != owner_id)
    attributes.each { |name, value| public_send("#{name}=", value) if respond_to?("#{name}=") }
    @wasalx_assignment_revision += 1 if assignment_changed
    updates << attributes
  end

  def with_lock
    yield
  end

  def reload
    self
  end
end

class Hash
  def deep_dup
    Marshal.load(Marshal.dump(self))
  end

  def deep_stringify_keys
    each_with_object({}) do |(key, value), result|
      result[key.to_s] = value.is_a?(Hash) ? value.deep_stringify_keys : value
    end
  end

  def symbolize_keys
    transform_keys(&:to_sym)
  end
end

class FakeLifecycleTransaction
  def initialize(deferred: false)
    @deferred = deferred
    @callbacks = []
  end

  def open?
    true
  end

  def after_commit(&block)
    @deferred ? @callbacks << block : block.call
  end

  def commit!
    @callbacks.shift.call until @callbacks.empty?
  end

  def rollback!
    @callbacks.clear
  end
end

class FakeLifecycleTicket
  attr_accessor :id, :number, :state_id, :updated_at, :previous_changes

  class << self
    attr_accessor :test_transaction

    def rows
      @rows ||= {}
    end

    def current_transaction
      test_transaction || FakeLifecycleTransaction.new
    end

    def exists?(id:, state_id:)
      rows[id]&.state_id == state_id
    end
  end

  def saved_change_to_state_id?
    previous_changes.key?('state_id')
  end


  def initialize(state_id: 4)
    @id = 42
    @number = '10382'
    @state_id = state_id
    @updated_at = Time.utc(2026, 8, 9, 12, 0, 0, 123_456)
    @previous_changes = { 'state_id' => [2, state_id] }
    self.class.rows[id] = self
  end
end

class FakeArticle
  include Ticket::Article::EnqueueCommunicateWasalxJob
  attr_accessor :id, :ticket_id, :internal, :sender_id, :type_id, :body,
                :content_type, :created_by_id, :created_by, :preferences,
                :attachments, :inline_attachments, :subject, :plain_body, :from,
                :message_id, :in_reply_to, :application_handle_info_postmaster,
                :created_at
  attr_reader :save_count

  def initialize(id: 9, ticket_id: 42)
    @id = id
    @ticket_id = ticket_id
    @internal = false
    @sender_id = 1
    @type_id = 10
    @body = 'Resolved'
    @subject = 'Agent reply'
    @content_type = 'text/plain'
    @created_by_id = 77
    @created_by = FakeUser.new(" Alice\n", 'Operator ')
    @preferences = {}
    @application_handle_info_postmaster = true
    @attachments = []
    @inline_attachments = []
    @save_count = 0
    @from = 'Customer <customer@acme.example>'
    @message_id = "zammad-message-#{id}"
    @created_at = Time.utc(2026, 8, 9, 12, 0, 0, 123_456)
  end

  def with_lock
    yield
  end

  def lock!
    self
  end

  def save!
    @save_count += 1
    self
  end

  def update!(changes)
    if changes.fetch(:preferences, {}).keys.any? { |key| key.start_with?('wasalx_email_routing_') } &&
       caller_locations.any? { |location| File.basename(location.path) == 'wasalx_ticket_routing_job.rb' }
      raise 'routing receipt mutation outside dispatcher transaction' unless Transaction.depth.to_i.positive?
    end
    changes.each { |name, value| public_send("#{name}=", value) }
    save!
  end

  def body_as_text
    plain_body || body
  end
end

class ZammadRuntimeContractTest < Minitest::Test
  CONCERN = Ticket::Article::EnqueueCommunicateWasalxJob
  TICKET_CONCERN = Ticket::EnqueueWasalxTicketStateJob

  def setup
    Setting.import_mode = false
    Locale.default = 'en-us'
    FakeLifecycleTicket.test_transaction = nil
    FakeLifecycleTicket.rows.clear
    CommunicateWasalxJob.reset_jobs!
    WasalxTicketStateJob.reset_jobs!
    WasalxTicketRoutingJob.reset_jobs!
    Transaction.calls = []
    Transaction.after_execute = nil
    Transaction.depth = 0
    Wasalx::Client.reset_test_state!
    Ticket.records = {}
    Ticket::Article.records = {}
    Ticket::Article.created_notes = []
    ENV['WASALX_TENANT_ID'] = TENANT_ID
    ENV['WASALX_CONTROL_URL'] = 'https://control.wasalx.test'
    ENV['WASALX_ZAMMAD_INSTANCE_ID'] = INSTANCE_ID
    ENV['WASALX_SERVICE_JWT_SECRET'] = 'test-secret-at-least-32-characters-long'
  end

  def register(article, ticket = FakeTicket.new(id: article.ticket_id))
    Ticket.records[ticket.id] = ticket
    Ticket::Article.records[article.id] = article
    [article, ticket]
  end

  def invoke_enqueue(article)
    article.extend(CONCERN)
    article.send(:ticket_article_enqueue_communicate_wasalx_job)
  end

  def invoke_routing_enqueue(article)
    article.extend(CONCERN)
    article.send(:ticket_article_enqueue_wasalx_routing_job)
  end

  def http_response(klass, code, body)
    response = klass.new('1.1', code, 'contract response')
    response.body = body
    response.instance_variable_set(:@read, true)
    response
  end

  def streaming_response(klass, code, chunks, headers = {})
    response = klass.new('1.1', code, 'contract response')
    headers.each { |name, value| response[name] = value }
    response.define_singleton_method(:read_body) { |&consumer| chunks.each { |chunk| consumer.call(chunk) } }
    response
  end

  def with_http_response(response)
    request = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |value| @use_ssl = value }
    fake_http.define_singleton_method(:use_ssl?) { @use_ssl == true }
    fake_http.define_singleton_method(:verify_mode=) { |_value| }
    fake_http.define_singleton_method(:open_timeout=) { |_value| }
    fake_http.define_singleton_method(:read_timeout=) { |_value| }
    fake_http.define_singleton_method(:start) { |&block| block.call(fake_http) }
    fake_http.define_singleton_method(:request) do |value, &consumer|
      request = value
      consumer.call(response) if consumer
      response
    end
    original = Net::HTTP.method(:new)
    Net::HTTP.singleton_class.send(:define_method, :new) { |_host, _port| fake_http }
    yield -> { request }
  ensure
    Net::HTTP.singleton_class.send(:define_method, :new, original)
  end

  def routing_responses(decision)
    route = {
      'route_id' => ROUTE_ID,
      'ticket_id' => '42',
      'source_article_id' => '9'
    }.merge(decision)
    lambda do |path, payload|
      if path == '/internal/v1/zammad/routing/acknowledgement'
        {
          'route_id' => ROUTE_ID,
          'acknowledged' => true,
          'application_status' => payload.fetch(:application_status),
          'observed_group_id' => payload.fetch(:observed_group_id),
          'observed_owner_id' => payload[:observed_owner_id],
          'duplicate' => false
        }
      else
        route
      end
    end
  end

  def perform_routing_decision(payload)
    WasalxTicketRoutingJob.new.perform(payload)
    WasalxTicketRoutingJob.enqueued_jobs.reverse_each do |arguments|
      acknowledgement = arguments.fetch(0)
      return acknowledgement if acknowledgement['phase'] == 'ACKNOWLEDGEMENT'
    end
    flunk 'routing decision did not durably enqueue an acknowledgement'
  end

  def perform_routing(payload)
    acknowledgement = perform_routing_decision(payload)
    WasalxTicketRoutingJob.new.perform(acknowledgement)
    acknowledgement
  end

  # Closed native Trigger fixture for the actual compiler, not a second client
  # matcher. Pinned Zammad Selector::Sql's non-JSON `is not` branch includes
  # IS NULL OR NOT IN; the package routing-status attribute is nullable text.
  def apply_native_queue_default(ticket, support_groups: ['1'], action: 'create')
    manifest = { 'client_routing' => { 'support_group_ids' => support_groups } }
    policy = { 'key' => ROUTE_ID, 'group_id' => '1', 'owner_id' => '7', 'enabled' => true }
    fields = Wasalx::RoutingConfiguration.new({}, manifest, nil).send(:trigger_fields, policy)
    matches = fields.fetch('condition').all? do |key, condition|
      actual = key == 'ticket.action' ? action : ticket.public_send(key.delete_prefix('ticket.'))
      values = Array(condition.fetch('value')).map(&:to_s)
      case condition.fetch('operator')
      when 'is' then !actual.nil? && values.include?(actual.to_s)
      when 'is not' then actual.nil? || !values.include?(actual.to_s)
      else raise 'Unsupported native Trigger fixture predicate'
      end
    end
    return false unless matches

    ticket.update!(owner_id: fields.fetch('perform').fetch('ticket.owner_id').fetch('value').to_i)
    true
  end

  def test_queue_default_and_email_callback_order_never_fabricates_a_manual_override
    %i[callback_first default_first].each do |order|
      setup
      article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
      ticket.owner_id = 1
      assert apply_native_queue_default(ticket) if order == :default_first
      invoke_routing_enqueue(article)
      payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
      assert_equal(order == :default_first ? 1 : 0, payload.fetch('expected_assignment_revision'))
      refute apply_native_queue_default(ticket) if order == :callback_first
      assert_equal payload.fetch('expected_assignment_revision'), ticket.wasalx_assignment_revision
      Wasalx::Client.response = routing_responses({
        'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
        'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7', 'owner_id' => '8'
      })
      acknowledgement = perform_routing(payload)
      assert_equal 'APPLIED', acknowledgement.fetch('application_status')
      assert_equal [7, 8, 'MATCHED'], [ticket.group_id, ticket.owner_id, ticket.wasalx_client_route_status]
    end
  end

  def test_native_queue_default_only_fills_an_unset_owner_on_plain_ui_create
    [nil, ''].each do |route_status|
      ticket = FakeTicket.new; ticket.owner_id = 1; ticket.wasalx_client_route_status = route_status
      assert apply_native_queue_default(ticket)
      assert_equal 7, ticket.owner_id
      assert_equal 1, ticket.wasalx_assignment_revision
    end
    [{ owner_id: 99 }, { group_id: 9 }, { wasalx_client_route_status: 'PENDING' }].each do |attributes|
      ticket = FakeTicket.new; ticket.owner_id = 1
      attributes.each { |key, value| ticket.public_send("#{key}=", value) }
      before = [ticket.group_id, ticket.owner_id, ticket.wasalx_assignment_revision]
      refute apply_native_queue_default(ticket)
      assert_equal before, [ticket.group_id, ticket.owner_id, ticket.wasalx_assignment_revision]
    end
    ticket = FakeTicket.new; ticket.owner_id = 1
    refute apply_native_queue_default(ticket, action: 'update')
    assert_equal 1, ticket.owner_id
  end

  def test_native_queue_default_preserves_a_real_manual_edit_after_callback_capture
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    ticket.owner_id = 1
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    ticket.update!(owner_id: 99)
    refute apply_native_queue_default(ticket)
    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7', 'owner_id' => '8'
    })
    acknowledgement = perform_routing(payload)
    assert_equal 'MANUAL_OVERRIDE', acknowledgement.fetch('application_status')
    assert_equal [1, 99, 'MANUAL_OVERRIDE'], [ticket.group_id, ticket.owner_id, ticket.wasalx_client_route_status]
  end

  def test_non_support_department_default_survives_unconfigured_email_callback
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    ticket.owner_id = 1
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    assert apply_native_queue_default(ticket, support_groups: ['9'])
    Wasalx::Client.response = routing_responses({ 'routed' => false, 'status' => 'UNCONFIGURED' })
    acknowledgement = perform_routing(payload)
    assert_equal 'APPLIED', acknowledgement.fetch('application_status')
    assert_equal [1, 7, 'UNCONFIGURED'], [ticket.group_id, ticket.owner_id, ticket.wasalx_client_route_status]
  end

  def test_concern_registers_routing_inside_the_article_transaction
    callbacks = []
    model = Class.new do
      define_singleton_method(:before_create) { |name| callbacks << name }
      define_singleton_method(:after_create) { |name| callbacks << name }
      define_singleton_method(:after_create_commit) { |name| callbacks << name }
    end
    model.class_eval(&CONCERN.instance_variable_get(:@wasalx_included_block))
    assert_equal [:ticket_article_preflight_wasalx_outbound, :ticket_article_enqueue_communicate_wasalx_job, :ticket_article_enqueue_wasalx_routing_job], callbacks
    assert_equal false, WasalxTicketRoutingJob.enqueue_after_transaction_commit
  end

  def test_customer_email_routes_the_existing_ticket_without_sending_content
    article, ticket = register(FakeArticle.new.tap do |value|
      value.sender_id = 2
      value.type_id = 12
      value.attachments = [FakeAttachment.new(91, 'manifest.pdf', 4096, { 'Mime-Type' => 'application/pdf' })]
      value.inline_attachments = [FakeAttachment.new(92, 'signature.png', 2048, { 'Mime-Type' => 'image/png' })]
    end)
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    assert_equal 'customer@acme.example', payload.fetch('sender_email')
    assert_equal 42, payload.fetch('ticket_id')
    assert_equal 9, payload.fetch('article_id')
    assert_equal 1, payload.fetch('expected_group_id')
    assert_equal 0, payload.fetch('expected_assignment_revision')
    assert_equal 'PENDING', ticket.wasalx_client_route_status
    assert_equal 1, payload.fetch('entry_group_id')
    assert_equal %w[admitted_at article_id entry_group_id expected_assignment_revision expected_group_id expected_owner_id instance_id sender_email tenant_id ticket_id ticket_number], payload.keys.sort

    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'MATCHED',
      'routing_version_id' => 'routing-v1', 'client_id' => 'acme', 'matched_by' => 'DOMAIN',
      'zammad_group_id' => '7', 'owner_id' => '8'
    })
    acknowledgement_payload = perform_routing(payload)
    call = Wasalx::Client.calls.first
    assert_equal '/internal/v1/zammad/routing', call.fetch(:path)
    assert_equal 'zammad:routing', call.fetch(:scope)
    refute call.fetch(:payload).key?(:body)
    assert_equal 7, ticket.group_id
    assert_equal 8, ticket.owner_id
    assert_equal 'MATCHED', ticket.wasalx_client_route_status
    assert_equal Array.new(3) { { reset_user_id: true } }, Transaction.calls
    acknowledgement = Wasalx::Client.calls.last
    assert_equal '/internal/v1/zammad/routing/acknowledgement', acknowledgement.fetch(:path)
    assert_equal 'APPLIED', acknowledgement.fetch(:payload).fetch(:application_status)
    assert_equal 'ACKNOWLEDGEMENT', acknowledgement_payload.fetch('phase')

    invoke_routing_enqueue(article)
    assert_equal 2, WasalxTicketRoutingJob.enqueued_jobs.length
  end

  def test_email_channel_ownership_stays_native_and_loop_safe
    ticket = FakeTicket.new
    rejected = [
      FakeArticle.new.tap { |article| article.sender_id = 1; article.type_id = 12 }, # public agent email reply
      FakeArticle.new.tap { |article| article.sender_id = 3; article.type_id = 12 }, # Zammad system delivery article
      FakeArticle.new.tap { |article| article.sender_id = 2; article.type_id = 11 }, # customer note
      FakeArticle.new.tap { |article| article.sender_id = 2; article.type_id = 12; article.internal = true },
    ]
    rejected.each do |article|
      register(article, ticket)
      invoke_routing_enqueue(article)
      invoke_enqueue(article)
    end
    assert_empty WasalxTicketRoutingJob.enqueued_jobs
    assert_empty CommunicateWasalxJob.enqueued_jobs

    ticket.wasalx_client_route_status = 'MATCHED'
    follow_up = FakeArticle.new.tap { |article| article.sender_id = 2; article.type_id = 12 }
    register(follow_up, ticket)
    invoke_routing_enqueue(follow_up)
    assert_empty WasalxTicketRoutingJob.enqueued_jobs
  end

  def test_email_routing_rejects_non_postmaster_and_automatic_customer_articles
    ticket = FakeTicket.new
    rejected = [
      FakeArticle.new.tap do |article|
        article.sender_id = 2
        article.type_id = 12
        article.application_handle_info_postmaster = false
      end,
      FakeArticle.new.tap do |article|
        article.sender_id = 2
        article.type_id = 12
        article.application_handle_info_postmaster = nil
      end,
      FakeArticle.new.tap do |article|
        article.sender_id = 2
        article.type_id = 12
        article.preferences = { 'is-auto-response' => true }
      end,
      FakeArticle.new.tap do |article|
        article.sender_id = 2
        article.type_id = 12
        article.preferences = { :'is-auto-response' => true }
      end,
    ]

    rejected.each do |article|
      register(article, ticket)
      invoke_routing_enqueue(article)
    end

    assert_empty WasalxTicketRoutingJob.enqueued_jobs
  end

  def test_first_email_atomically_pins_the_only_routing_job
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    later = FakeArticle.new(id: 10).tap { |value| value.sender_id = 2; value.type_id = 12 }
    register(later, ticket)
    invoke_routing_enqueue(article)
    invoke_routing_enqueue(later)
    assert_equal 1, WasalxTicketRoutingJob.enqueued_jobs.length
    assert_equal 9, WasalxTicketRoutingJob.enqueued_jobs.first.first.fetch('article_id')
    assert_equal 'PENDING', ticket.wasalx_client_route_status
    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'MATCHED',
      'routing_version_id' => 'routing-v1', 'client_id' => 'acme', 'matched_by' => 'EMAIL',
      'zammad_group_id' => '7', 'owner_id' => '8'
    })
    perform_routing(WasalxTicketRoutingJob.enqueued_jobs.first.fetch(0))
    assert_equal 42, ticket.id
    assert_equal 2, ticket.updates.length
    assert_equal 7, ticket.group_id
    assert_equal 8, ticket.owner_id
  end

  def test_email_routing_retries_the_frozen_receipt_after_a_committed_response_is_lost
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    responder = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    })
    acknowledgement_attempts = 0
    committed_receipt = nil
    Wasalx::Client.response = lambda do |path, input|
      if path == '/internal/v1/zammad/routing/acknowledgement'
        acknowledgement_attempts += 1
        if acknowledgement_attempts == 1
          committed_receipt = input.dup
          raise Wasalx::Client::TemporaryRequestFailed, 'response lost after receipt commit'
        end
        raise 'acknowledgement tuple changed across retry' unless input == committed_receipt
        return {
          'route_id' => input.fetch(:route_id), 'acknowledged' => true,
          'application_status' => input.fetch(:application_status),
          'observed_group_id' => input.fetch(:observed_group_id),
          'observed_owner_id' => input[:observed_owner_id], 'duplicate' => true
        }
      end
      responder.call(path, input)
    end

    acknowledgement = perform_routing_decision(payload)
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketRoutingJob.new.perform(acknowledgement) }
    ticket.update!(group_id: 99)
    WasalxTicketRoutingJob.new.perform(JSON.parse(JSON.generate(acknowledgement)))
    WasalxTicketRoutingJob.new.perform(payload)
    assert_equal 3, ticket.updates.length
    assert_equal 2, WasalxTicketRoutingJob.enqueued_jobs.length
    assert_equal 2, acknowledgement_attempts
  end

  def test_email_routing_rejects_an_inconsistent_success_before_ticket_mutation
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    Wasalx::Client.response = {
      'route_id' => ROUTE_ID, 'ticket_id' => '42', 'source_article_id' => '9',
      'routed' => false, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    }
    WasalxTicketRoutingJob.new.perform(WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0))
    assert_equal 'FAILED_TERMINAL', article.preferences['wasalx_email_routing_state']
    assert_equal [{ wasalx_client_route_status: 'PENDING' }, { wasalx_client_route_status: 'FAILED_TERMINAL' }], ticket.updates
    assert_equal 1, Ticket::Article.created_notes.length
  end

  def test_email_routing_preserves_a_manual_assignment_change
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    ticket.update!(group_id: 99)
    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'FALLBACK',
      'routing_version_id' => 'routing-v1', 'matched_by' => 'FALLBACK', 'zammad_group_id' => '7'
    })
    perform_routing(payload)
    assert_equal 99, ticket.group_id
    assert_equal 'MANUAL_OVERRIDE', ticket.wasalx_client_route_status
    assert_equal 'MANUAL_OVERRIDE', Wasalx::Client.calls.last.fetch(:payload).fetch(:application_status)
  end

  def test_email_routing_detects_group_and_owner_changes_that_are_reverted
    [{ group_id: 99 }, { owner_id: 99 }].each do |change|
      setup
      article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
      invoke_routing_enqueue(article)
      payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
      original = change.transform_values { |_value| change.key?(:group_id) ? 1 : 2 }
      ticket.update!(change)
      ticket.update!(original)
      Wasalx::Client.response = routing_responses({
        'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
        'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
      })

      perform_routing(payload)

      assert_equal 'MANUAL_OVERRIDE', ticket.wasalx_client_route_status
      assert_equal 2, ticket.wasalx_assignment_revision
      assert_equal 'MANUAL_OVERRIDE', Wasalx::Client.calls.last.fetch(:payload).fetch(:application_status)
    end
  end

  def test_email_routing_reclassifies_a_synchronous_dispatcher_assignment
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    })
    Transaction.after_execute = lambda do
      Transaction.after_execute = nil
      ticket.update!(group_id: 99)
    end

    perform_routing(payload)

    acknowledgement = Wasalx::Client.calls.last.fetch(:payload)
    assert_equal 'MANUAL_OVERRIDE', acknowledgement.fetch(:application_status)
    assert_equal '99', acknowledgement.fetch(:observed_group_id)
    assert_equal 'MANUAL_OVERRIDE', ticket.wasalx_client_route_status
    assert_equal 4, Transaction.calls.length
  end

  def test_email_routing_retries_a_malformed_success_acknowledgement
    article, = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    responder = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    })
    Wasalx::Client.response = lambda do |path, input|
      path.end_with?('/acknowledgement') ? { 'acknowledged' => false } : responder.call(path, input)
    end

    acknowledgement = perform_routing_decision(payload)
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketRoutingJob.new.perform(acknowledgement) }
  end

  def test_email_routing_acknowledgement_records_its_own_terminal_failure_note
    Locale.default = 'ar'
    article, = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    Wasalx::Client.response = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    })
    acknowledgement = perform_routing_decision(payload)
    article.preferences['wasalx_email_routing_failure_noted'] = true
    Wasalx::Client.response = lambda do |_path, _input|
      raise Wasalx::Client::PermanentRequestFailed, 'acknowledgement rejected'
    end

    WasalxTicketRoutingJob.new.perform(acknowledgement)

    assert_equal 'FAILED_TERMINAL', article.preferences['wasalx_email_routing_ack_state']
    assert_equal true, article.preferences['wasalx_email_routing_ack_failure_noted']
    assert_equal 1, Ticket::Article.created_notes.length
    note = Ticket::Article.created_notes.first
    assert_equal 'ACKNOWLEDGEMENT', note.fetch(:preferences).fetch(:wasalx_email_routing_failure_phase)
    assert_equal true, note.fetch(:internal)
    assert_equal 'تعذّر على WasalX تطبيق قرار توجيه البريد الإلكتروني. راجع إعدادات التوجيه، ثم أعد المحاولة من إجراء WasalX. (WX-EMAIL-ROUTING-TERMINAL)', note.fetch(:body)
  end

  def test_email_routing_replay_rejects_stale_stored_provenance
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    article.preferences['wasalx_email_routing_state'] = 'FAILED_TERMINAL'
    article.preferences['wasalx_email_routing_payload']['article_id'] = article.id + 1
    WasalxTicketRoutingJob.reset_jobs!

    assert_raises(Wasalx::Client::PermanentRequestFailed) do
      WasalxTicketRoutingJob.replay!(ticket: ticket, article: article)
    end

    assert_empty WasalxTicketRoutingJob.enqueued_jobs
    assert_equal 'FAILED_TERMINAL', article.preferences['wasalx_email_routing_state']
  end

  def test_email_routing_replay_dispatches_without_replacing_the_agent_actor
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    article.preferences['wasalx_email_routing_state'] = 'FAILED_TERMINAL'
    ticket.wasalx_client_route_status = 'FAILED_TERMINAL'
    WasalxTicketRoutingJob.reset_jobs!

    assert_equal({ state: 'PENDING', duplicate: false }, WasalxTicketRoutingJob.replay!(ticket: ticket, article: article))
    assert_equal [{}], Transaction.calls
    assert_equal 'PENDING', article.preferences['wasalx_email_routing_state']
    assert_equal 'PENDING', ticket.wasalx_client_route_status
    assert_equal 1, WasalxTicketRoutingJob.enqueued_jobs.length
  end

  def test_email_routing_receipt_survives_more_than_eight_failures_and_payload_reload
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.fetch(0).fetch(0)
    responder = routing_responses({
      'routed' => true, 'status' => 'MATCHED', 'routing_version_id' => 'routing-v1',
      'client_id' => 'acme', 'matched_by' => 'EMAIL', 'zammad_group_id' => '7'
    })
    acknowledgement_attempts = 0
    Wasalx::Client.response = lambda do |path, input|
      if path.end_with?('/acknowledgement') && (acknowledgement_attempts += 1) <= 9
        raise Wasalx::Client::TemporaryRequestFailed, 'control API unavailable'
      end
      responder.call(path, input)
    end

    acknowledgement = perform_routing_decision(payload)
    9.times do |index|
      reloaded_payload = JSON.parse(JSON.generate(acknowledgement))
      job = WasalxTicketRoutingJob.new
      job.perform_attempt(reloaded_payload, index + 1)
      assert job.retry_wait.positive?
    end
    WasalxTicketRoutingJob.new.perform_attempt(JSON.parse(JSON.generate(acknowledgement)), 10)

    assert_equal 10, acknowledgement_attempts
    assert_equal 'SUCCEEDED', article.preferences['wasalx_email_routing_ack_state']
    assert_equal 1, ticket.updates.count { |update| update.key?(:wasalx_client_routing_version_id) }
    assert_equal 'MATCHED', ticket.wasalx_client_route_status
  end

  def test_email_routing_retry_exhaustion_records_a_terminal_outcome
    article, ticket = register(FakeArticle.new.tap { |value| value.sender_id = 2; value.type_id = 12 })
    invoke_routing_enqueue(article)
    payload = WasalxTicketRoutingJob.enqueued_jobs.shift.fetch(0)
    Wasalx::Client.error = Wasalx::Client::TemporaryRequestFailed.new('control API unavailable')
    logs = StringIO.new
    logger = Logger.new(logs)
    attempts = ENV.fetch('WASALX_ROUTING_RETRY_ATTEMPTS', '10').to_i
    base_delay = ENV.fetch('WASALX_ROUTING_RETRY_WAIT_SECONDS', '30').to_i

    assert_equal false, WasalxTicketRoutingJob.log_arguments
    (1..attempts).each do |attempt|
      job = WasalxTicketRoutingJob.new
      job.logger = logger
      job.perform_attempt(JSON.parse(JSON.generate(payload)), attempt)
      if attempt < attempts
        assert_equal [attempt**2 * base_delay, 900].min, job.retry_wait
        assert_equal 'PENDING', article.preferences['wasalx_email_routing_state']
        assert_empty Ticket::Article.created_notes
      else
        assert_nil job.retry_wait
      end
    end

    assert_equal attempts, Wasalx::Client.calls.length
    assert_equal 'FAILED_TERMINAL', article.preferences['wasalx_email_routing_state']
    assert_equal 'FAILED_TERMINAL', ticket.wasalx_client_route_status
    assert_equal 1, Ticket::Article.created_notes.length
    assert_equal 'WasalX could not apply this email routing decision. Review the routing setup, then retry from the WasalX action. (WX-EMAIL-ROUTING-TERMINAL)', Ticket::Article.created_notes.first.fetch(:body)
    assert_includes logs.string, 'event=wasalx_ticket_routing_retry_exhausted job_id=b13edf7f-838b-4409-b57b-d661a101c8ed ticket_id=42 article_id=9'
    refute_includes logs.string, 'control API unavailable'
    refute_includes logs.string, payload.fetch('sender_email')
  end

  def test_only_public_agent_wasalx_articles_enqueue
    allowed = FakeArticle.new
    invoke_enqueue(allowed)
    assert_equal [[9]], CommunicateWasalxJob.enqueued_jobs

    CommunicateWasalxJob.reset_jobs!
    rejected = [
      FakeArticle.new.tap { |article| article.internal = true },
      FakeArticle.new.tap { |article| article.sender_id = 2 },
      FakeArticle.new.tap { |article| article.sender_id = 3 },
      FakeArticle.new.tap { |article| article.sender_id = nil },
      FakeArticle.new.tap { |article| article.type_id = 11 },
      FakeArticle.new.tap { |article| article.type_id = nil },
      FakeArticle.new.tap { |article| article.preferences['wasalx_origin'] = 'provider' },
      FakeArticle.new.tap { |article| article.subject = 'Sent from WhatsApp device' }
    ]
    rejected.each { |article| invoke_enqueue(article) }
    assert_empty CommunicateWasalxJob.enqueued_jobs

    Setting.import_mode = true
    invoke_enqueue(FakeArticle.new)
    assert_empty CommunicateWasalxJob.enqueued_jobs
  end

  def test_ticket_state_callback_is_after_commit_and_captures_a_stable_transition
    callback = nil
    model = Class.new do
      define_singleton_method(:after_update) { |name| callback = name }
    end
    model.class_eval(&TICKET_CONCERN.instance_variable_get(:@wasalx_included_block))
    assert_equal :ticket_enqueue_wasalx_ticket_state_job, callback

    ticket = FakeLifecycleTicket.new
    ticket.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    payload = WasalxTicketStateJob.enqueued_jobs.fetch(0).fetch(0)
    assert_equal TENANT_ID, payload.fetch('tenant_id')
    assert_equal 42, payload.fetch('ticket_id')
    assert_equal 'closed', payload.fetch('state_type_name')
    assert_equal 'ticket-state:42:4:2026-08-09T12:00:00.123456Z', payload.fetch('idempotency_key')

    WasalxTicketStateJob.new.perform(payload)
    call = Wasalx::Client.calls.last
    assert_equal '/internal/v1/zammad/ticket-state', call.fetch(:path)
    assert_equal 'zammad:ticket-state', call.fetch(:scope)
    assert_equal payload.fetch('idempotency_key'), call.fetch(:payload).fetch(:idempotency_key)
  end

  def test_native_state_capture_rejects_an_unavailable_public_transaction
    rejected = Object.new
    rejected.define_singleton_method(:open?) { false }
    rejected.define_singleton_method(:after_commit) { raise 'Unavailable transaction invoked callback' }
    FakeLifecycleTicket.test_transaction = rejected
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    assert_raises(ArgumentError) { ticket.send(:ticket_enqueue_wasalx_ticket_state_job) }
    assert_empty WasalxTicketStateJob.enqueued_jobs
  end

  def test_native_state_capture_survives_later_contact_save_on_another_instance
    transaction = FakeLifecycleTransaction.new(deferred: true)
    FakeLifecycleTicket.test_transaction = transaction
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    original_time = ticket.updated_at.utc.iso8601(6)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_empty WasalxTicketStateJob.enqueued_jobs
    replacement = FakeLifecycleTicket.new(state_id: 4)
    replacement.updated_at += 60
    replacement.previous_changes = { 'title' => ['Old', 'Contact save'] }
    replacement.extend(TICKET_CONCERN).send(:ticket_enqueue_wasalx_ticket_state_job)
    article, = register(FakeArticle.new)
    transaction.commit!
    assert_equal 1, WasalxTicketStateJob.enqueued_jobs.length
    payload = WasalxTicketStateJob.enqueued_jobs.first.first
    assert_equal original_time, payload.fetch('transitioned_at')
    assert_equal [article.id], payload.fetch('pending_article_ids')
    assert_equal 'ticket-state:42:4:' + original_time, payload.fetch('idempotency_key')
  end

  def test_native_state_capture_is_discarded_on_rollback_and_nonstate_save_does_not_leak
    transaction = FakeLifecycleTransaction.new(deferred: true)
    FakeLifecycleTicket.test_transaction = transaction
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    transaction.rollback!
    transaction = FakeLifecycleTransaction.new(deferred: true)
    FakeLifecycleTicket.test_transaction = transaction
    ticket.previous_changes = { 'title' => ['Old', 'Later save'] }
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    transaction.commit!
    assert_empty WasalxTicketStateJob.enqueued_jobs
  end

  def test_native_state_capture_drops_superseded_closed_state_in_the_same_transaction
    transaction = FakeLifecycleTransaction.new(deferred: true)
    FakeLifecycleTicket.test_transaction = transaction
    closed = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    closed.send(:ticket_enqueue_wasalx_ticket_state_job)
    opened = FakeLifecycleTicket.new(state_id: 2).extend(TICKET_CONCERN)
    opened.updated_at += 1
    opened.send(:ticket_enqueue_wasalx_ticket_state_job)
    transaction.commit!
    assert_equal 1, WasalxTicketStateJob.enqueued_jobs.length
    assert_equal 2, WasalxTicketStateJob.enqueued_jobs.first.first.fetch('state_id')
  end

  def test_ticket_state_callback_ignores_non_transitions_and_imports
    ticket = FakeLifecycleTicket.new(state_id: 2)
    ticket.extend(TICKET_CONCERN)
    ticket.previous_changes = { 'title' => ['Old', 'New'] }
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_empty WasalxTicketStateJob.enqueued_jobs

    ticket.previous_changes = { 'state_id' => [4, 2] }
    Setting.import_mode = true
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_empty WasalxTicketStateJob.enqueued_jobs
  end

  def test_close_waits_for_committed_reply_admission_without_changing_transition
    article, = register(FakeArticle.new)
    ticket = FakeLifecycleTicket.new
    ticket.extend(TICKET_CONCERN)
    # Native update creates its reply later than ticket.updated_at, but before
    # commit. The after-commit snapshot must include it, without a time cutoff.
    article.created_at = ticket.updated_at + 0.1
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    payload = WasalxTicketStateJob.enqueued_jobs.fetch(0).fetch(0)
    assert_equal [article.id], payload.fetch('pending_article_ids')

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketStateJob.new.perform(payload) }
    assert_empty Wasalx::Client.calls
    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
    Wasalx::Client.response = { 'state' => 'APPLIED' }
    WasalxTicketStateJob.new.perform(payload)
    sent = Wasalx::Client.calls.last.fetch(:payload)
    assert_equal payload.fetch('transitioned_at'), sent.fetch(:transitioned_at)
    assert_equal payload.fetch('idempotency_key'), sent.fetch(:idempotency_key)
    refute sent.key?(:pending_article_ids)
    assert_equal 1, Wasalx::Client.calls.count { |call| call.fetch(:path).end_with?('/outbound') }
  end

  def test_close_retries_only_projection_while_accepted_delivery_is_unsettled
    article, = register(FakeArticle.new)
    article.preferences['wasalx_delivery_id'] = 'delivery-1'
    payload = { 'ticket_id' => 42, 'transitioned_at' => '2026-08-09T12:00:00.123456Z',
                'idempotency_key' => 'stable-close-key', 'pending_article_ids' => [9] }
    Wasalx::Client.response = { 'state' => 'BLOCKED_EFFECTS' }
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketStateJob.new.perform(payload) }
    Wasalx::Client.response = { 'state' => 'APPLIED' }
    WasalxTicketStateJob.new.perform(payload)
    assert_equal 2, Wasalx::Client.calls.size
    assert_equal Wasalx::Client.calls.first, Wasalx::Client.calls.last
    assert Wasalx::Client.calls.all? { |call| call.fetch(:path).end_with?('/ticket-state') }
  end

  def test_close_snapshot_excludes_non_outbound_and_already_admitted_articles
    excluded = [
      ->(a) { a.internal = true }, ->(a) { a.sender_id = 2 }, ->(a) { a.sender_id = 3 },
      ->(a) { a.type_id = 11 }, ->(a) { a.type_id = 12 },
      ->(a) { a.preferences['wasalx_origin'] = 'provider' },
      ->(a) { a.subject = 'Sent from WhatsApp device' },
      ->(a) { a.preferences['wasalx_delivery_id'] = 'accepted' }
    ]
    excluded.each_with_index { |change, i| register(FakeArticle.new(id: i + 20).tap(&change)) }
    pending, = register(FakeArticle.new)
    # A generic terminal native status does not prove definitive non-admission.
    pending.preferences['wasalx_delivery_state'] = 'FAILED_TERMINAL'
    ticket = FakeLifecycleTicket.new
    ticket.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    payload = WasalxTicketStateJob.enqueued_jobs.fetch(0).fetch(0)
    assert_equal [9], payload.fetch('pending_article_ids')
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketStateJob.new.perform(payload) }
    later, = register(FakeArticle.new(id: 99))
    pending.preferences['wasalx_delivery_id'] = 'accepted'
    Wasalx::Client.response = { 'state' => 'APPLIED' }
    WasalxTicketStateJob.new.perform(payload)
    assert_empty later.preferences
    assert_equal [9], payload.fetch('pending_article_ids')
    open_ticket = FakeLifecycleTicket.new(state_id: 2).extend(TICKET_CONCERN)
    open_ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_equal [], WasalxTicketStateJob.enqueued_jobs.last.fetch(0).fetch('pending_article_ids')
  end

  def test_close_holds_missing_moved_or_reclassified_captured_replies
    payload = { 'ticket_id' => 42, 'pending_article_ids' => [9] }
    changes = [->(a) { Ticket::Article.records.delete(a.id) },
               ->(a) { a.ticket_id = 43 }, ->(a) { a.internal = true },
               ->(a) { a.preferences['wasalx_origin'] = 'provider' }]
    changes.each do |change|
      article, = register(FakeArticle.new)
      article.preferences['wasalx_delivery_id'] = 'accepted'
      change.call(article)
      assert_raises(Wasalx::Client::TemporaryRequestFailed) { WasalxTicketStateJob.new.perform(payload) }
    end
    assert_empty Wasalx::Client.calls
  end

  def test_imported_create_does_not_block_a_later_normal_close
    article, = register(FakeArticle.new)
    Setting.import_mode = true
    article.send(:ticket_article_preflight_wasalx_outbound)
    invoke_enqueue(article)
    assert_equal true, article.preferences['wasalx_imported']
    assert_empty CommunicateWasalxJob.enqueued_jobs
    Setting.import_mode = false
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    payload = WasalxTicketStateJob.enqueued_jobs.last.fetch(0)
    assert_empty payload.fetch('pending_article_ids')
    Wasalx::Client.response = { 'state' => 'APPLIED' }
    WasalxTicketStateJob.new.perform(payload)
    assert_equal 1, Wasalx::Client.calls.size
  end

  def test_normal_outbound_preflight_removes_a_supplied_import_exemption
    article, = register(FakeArticle.new)
    article.preferences['wasalx_imported'] = true
    article.preferences[:wasalx_imported] = true
    article.send(:ticket_article_preflight_wasalx_outbound)
    refute article.preferences.key?('wasalx_imported')
    refute article.preferences.key?(:wasalx_imported)
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_equal [article.id], WasalxTicketStateJob.enqueued_jobs.last.fetch(0).fetch('pending_article_ids')
  end

  def test_noncommunicative_create_cannot_supply_an_import_exemption
    article, = register(FakeArticle.new)
    article.internal = true
    article.preferences['wasalx_imported'] = true
    article.preferences[:wasalx_imported] = true
    article.send(:ticket_article_preflight_wasalx_outbound)
    assert_empty Wasalx::Client.calls
    refute article.preferences.key?('wasalx_imported')
    refute article.preferences.key?(:wasalx_imported)
    article.internal = false
    ticket = FakeLifecycleTicket.new.extend(TICKET_CONCERN)
    ticket.send(:ticket_enqueue_wasalx_ticket_state_job)
    assert_equal [article.id], WasalxTicketStateJob.enqueued_jobs.last.fetch(0).fetch('pending_article_ids')
  end

  def test_job_uses_zammad_retry_contract_for_temporary_failures
    contract = CommunicateWasalxJob.retry_contract
    assert_equal Wasalx::Client::TemporaryRequestFailed, contract.fetch(:error)
    assert_equal 4, contract.fetch(:attempts)
    assert_respond_to contract.fetch(:wait), :call
    state_contract = WasalxTicketStateJob.retry_contract
    assert_equal Wasalx::Client::TemporaryRequestFailed, state_contract.fetch(:error)
    assert_equal 8, state_contract.fetch(:attempts)
    assert_respond_to state_contract.fetch(:wait), :call
  end

  def test_real_client_emits_idempotency_and_classifies_http_responses
    success = http_response(Net::HTTPOK, '200', '{"id":"delivery-1","state":"QUEUED"}')
    with_http_response(success) do |captured_request|
      result = Wasalx::Client.http_post(
        '/internal/v1/zammad/outbound',
      { idempotency_key: "zammad:#{TENANT_ID}:#{INSTANCE_ID}:42:9", body: 'Resolved' },
        scope: 'zammad:outbound'
      )
      assert_equal({ 'id' => 'delivery-1', 'state' => 'QUEUED' }, result)
      request = captured_request.call
      assert_equal "zammad:#{TENANT_ID}:#{INSTANCE_ID}:42:9", request['Idempotency-Key']
      assert_match(/^Bearer /, request['Authorization'])
      assert_equal 'application/json', request['Content-Type']
    end

    temporary = http_response(Net::HTTPServiceUnavailable, '503', '{}')
    with_http_response(temporary) do
      assert_raises(Wasalx::Client::TemporaryRequestFailed) do
        Wasalx::Client.http_post('/internal/v1/zammad/outbound', {}, scope: 'zammad:outbound')
      end
    end

    permanent = http_response(Net::HTTPBadRequest, '400', '{}')
    with_http_response(permanent) do
      assert_raises(Wasalx::Client::PermanentRequestFailed) do
        Wasalx::Client.http_post('/internal/v1/zammad/outbound', {}, scope: 'zammad:outbound')
      end
    end

    malformed = http_response(Net::HTTPOK, '200', 'true')
    with_http_response(malformed) do
      assert_raises(Wasalx::Client::TemporaryRequestFailed) do
        Wasalx::Client.http_post('/internal/v1/zammad/outbound', {}, scope: 'zammad:outbound')
      end
    end

    missing = http_response(Net::HTTPNotFound, '404', '{"error":"private upstream details"}')
    with_http_response(missing) do
      error = assert_raises(Wasalx::Client::PermanentRequestFailed) do
        Wasalx::Client.http_post('/internal/v1/zammad/outbound', {}, scope: 'zammad:outbound')
      end
      assert_equal 404, error.http_status
      refute error.retryable?
      refute_includes error.message, 'private upstream details'
    end
  end

  def test_preflight_and_delivery_preserve_native_admin_boundary
    [false, true].each do |admin|
      Wasalx::Client.reset_test_state!
      article, = register(FakeArticle.new)
      article.created_by.group_admin = admin
      assert article.created_by.permissions?('ticket.agent.wasalx_groups_admin')
      article.extend(CONCERN)
      assert article.send(:ticket_article_preflight_wasalx_outbound)
      Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
      assert_equal 2, Wasalx::Client.calls.length
      Wasalx::Client.calls.each do |call|
        assert_equal admin, call.fetch(:actor).fetch(:group_admin)
      end
    end
  end

  def test_real_client_streams_media_with_a_hard_size_type_and_digest_boundary
    payload = 'streamed'.b
    success = streaming_response(Net::HTTPOK, '200', ['str'.b, 'eamed'.b], {
      'Content-Length' => payload.bytesize.to_s,
      'Content-Type' => 'image/png; charset=binary'
    })
    with_http_response(success) do |captured_request|
      result = Wasalx::Client.download(
        'https://media.example.invalid/object', payload.bytesize,
        expected_content_type: 'image/png', expected_sha256: Digest::SHA256.hexdigest(payload)
      )
      assert_equal payload, result.fetch(:data)
      assert_equal 'image/png', result.fetch(:content_type)
      assert_equal 'identity', captured_request.call['Accept-Encoding']
    end

    failures = [
      streaming_response(Net::HTTPOK, '200', [payload], { 'Content-Type' => 'image/png' }),
      streaming_response(Net::HTTPOK, '200', [payload], { 'Content-Length' => 'invalid', 'Content-Type' => 'image/png' }),
      streaming_response(Net::HTTPOK, '200', [payload], { 'Content-Length' => (payload.bytesize + 1).to_s, 'Content-Type' => 'image/png' }),
      streaming_response(Net::HTTPOK, '200', [payload], { 'Content-Length' => payload.bytesize.to_s, 'Content-Type' => 'text/plain' }),
      streaming_response(Net::HTTPOK, '200', [payload, 'x'.b], { 'Content-Length' => payload.bytesize.to_s, 'Content-Type' => 'image/png' }),
      streaming_response(Net::HTTPOK, '200', ['short'.b], { 'Content-Length' => payload.bytesize.to_s, 'Content-Type' => 'image/png' })
    ]
    failures.each do |response|
      with_http_response(response) do
        assert_raises(Wasalx::Client::PermanentRequestFailed) do
          Wasalx::Client.download(
            'https://media.example.invalid/object', payload.bytesize,
            expected_content_type: 'image/png', expected_sha256: Digest::SHA256.hexdigest(payload)
          )
        end
      end
    end
    with_http_response(success) do
      assert_raises(Wasalx::Client::PermanentRequestFailed) do
        Wasalx::Client.download(
          'https://media.example.invalid/object', payload.bytesize,
          expected_content_type: 'image/png', expected_sha256: '0' * 64
        )
      end
    end
  end

  def test_real_client_binds_the_exact_request_and_detaches_large_agent_group_sets
    success = http_response(Net::HTTPOK, '200', '{"accepted":true}')
    groups = (1..101).to_a
    actor = { user_id: 17, group_ids: groups, group_admin: false }
    path = '/internal/v1/zammad/group-workspace/groups/12000000-0000-4000-8000-000000000001/send'
    payload = { message: 'Bound request', idempotency_key: 'group-workspace:17:request-1' }

    with_http_response(success) do |captured_request|
      Wasalx::Client.http_post(path, payload, scope: 'zammad:groups', actor: actor)
      request = captured_request.call
      group_header = request['X-Wasalx-Zammad-Groups']
      claims = JSON.parse(Base64.urlsafe_decode64(request['Authorization'].delete_prefix('Bearer ').split('.').fetch(1)))

      assert_equal groups.map(&:to_s), JSON.parse(Zlib::Inflate.inflate(Base64.urlsafe_decode64(group_header)))
      assert_equal 'POST', claims.fetch('http_method')
      assert_equal path, claims.fetch('http_target')
      assert_equal Digest::SHA256.hexdigest(request.body), claims.fetch('http_body_sha256')
      assert_equal Digest::SHA256.hexdigest(group_header), claims.fetch('zammad_group_ids_sha256')
      refute claims.key?('zammad_group_ids')
    end
  end

  def test_real_client_fails_closed_instead_of_truncating_an_oversized_agent_group_set
    actor = { user_id: 17, group_ids: (1..25_000).to_a, group_admin: false }
    error = assert_raises(ArgumentError) { Wasalx::Client.send(:actor_group_header, actor) }

    assert_equal 'Invalid Zammad agent groups', error.message
  end

  def test_delivery_has_one_idempotent_effect_and_sanitized_identity_and_media
    article, ticket = register(FakeArticle.new)
    article.body = '<p>Resolved</p>'
    article.content_type = 'text/html'
    article.plain_body = 'Resolved'
    attachment = FakeAttachment.new(44, "../private\nimage.png", 1234, { 'Content-Type' => 'image/png' })
    article.attachments = [attachment]
    article.inline_attachments = [attachment]

    service = Service::Ticket::Article::Type::WasalxGroupMessage::Deliver
    assert_equal article, service.execute(article_id: article.id)
    assert_equal article, service.execute(article_id: article.id)

    assert_equal 1, Wasalx::Client.calls.length
    call = Wasalx::Client.calls.first
    assert_equal '/internal/v1/zammad/outbound', call.fetch(:path)
    assert_equal 'zammad:outbound', call.fetch(:scope)
    assert_equal({ user_id: 77, group_ids: [4, 9], group_admin: false }, call.fetch(:actor))
    payload = call.fetch(:payload)
    assert_equal "zammad:#{TENANT_ID}:#{INSTANCE_ID}:42:9", payload.fetch(:idempotency_key)
    assert_equal false, payload.fetch(:internal)
    assert_equal 'Resolved', payload.fetch(:body)
    assert_equal 'text/plain', payload.fetch(:content_type)
    refute payload.key?(:reply_to_message_id)
    refute payload.key?(:reply_to_article_id)
    assert_equal({ id: '77', display_name: 'Alice Operator' }, payload.fetch(:agent))
    assert_equal(
      [{ id: '44', filename: 'private image.png', content_type: 'image/png', size: 1234 }],
      payload.fetch(:attachments)
    )
    refute payload.key?(:agent_prefix)
    refute payload.fetch(:attachments).first.key?(:url)
    assert_equal 'delivery-1', article.preferences.fetch('wasalx_delivery_id')
    assert_equal 'QUEUED', article.preferences.fetch('wasalx_delivery_state')
    assert_equal({ wasalx_delivery_status: 'QUEUED' }, ticket.updates.last)
    assert_empty Ticket::Article.created_notes
  end

  def test_html_empty_paragraph_preserves_media_only_outbound_payload
    article, = register(FakeArticle.new)
    article.body = '<p><br></p>'
    article.content_type = 'text/html'
    article.plain_body = ''
    article.attachments = [FakeAttachment.new(44, 'safe-retry.png', 4, { 'Content-Type' => 'image/png' })]

    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)

    payload = Wasalx::Client.calls.fetch(0).fetch(:payload)
    assert_equal '', payload.fetch(:body)
    assert_equal(
      [{ id: '44', filename: 'safe-retry.png', content_type: 'image/png', size: 4 }],
      payload.fetch(:attachments)
    )
  end

  def test_media_only_empty_html_enqueues_and_delivers_inline_attachments_once
    article, = register(FakeArticle.new)
    article.body = '<p><br></p>'
    article.content_type = 'text/html'
    article.plain_body = ''
    article.inline_attachments = [FakeAttachment.new(45, 'inline.png', 4, { 'Content-Type' => 'image/png' })]

    invoke_enqueue(article)
    assert_equal [[article.id]], CommunicateWasalxJob.enqueued_jobs
    job = CommunicateWasalxJob.new
    2.times { job.perform(article.id) }

    assert_equal 1, Wasalx::Client.calls.length
    payload = Wasalx::Client.calls.first.fetch(:payload)
    assert_equal '', payload.fetch(:body)
    assert_equal 'text/plain', payload.fetch(:content_type)
    assert_equal(
      [{ id: '45', filename: 'inline.png', content_type: 'image/png', size: 4 }],
      payload.fetch(:attachments)
    )
  end

  def test_group_workspace_ticket_reply_does_not_require_an_automation_reference
    article, ticket = register(FakeArticle.new)
    ticket.wasalx_reference = nil

    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)

    assert_equal 1, Wasalx::Client.calls.length
    refute Wasalx::Client.calls.first.fetch(:payload).key?(:reply_to_message_id)
    refute Wasalx::Client.calls.first.fetch(:payload).key?(:reply_to_article_id)
  end

  def test_delivery_quotes_the_exact_selected_whatsapp_message
    article, ticket = register(FakeArticle.new)
    source = FakeArticle.new(id: 8)
    source.sender_id = 2
    source.preferences['wasalx_external_message_id'] = 'provider-message-8'
    Ticket::Article.records[source.id] = source
    article.in_reply_to = source.message_id

    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)

    assert_equal '8', Wasalx::Client.calls.first.fetch(:payload).fetch(:reply_to_article_id)
    refute Wasalx::Client.calls.first.fetch(:payload).key?(:reply_to_message_id)
    assert_equal ticket.id, source.ticket_id

    missing = FakeArticle.new(id: 10)
    missing.in_reply_to = 'missing-zammad-message'
    register(missing, ticket)
    assert_raises(Wasalx::Client::PermanentRequestFailed) do
      Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: missing.id)
    end
    assert_equal 1, Wasalx::Client.calls.length
  end

  def test_delivery_quotes_agent_article_without_provider_preferences
    article, = register(FakeArticle.new)
    source = FakeArticle.new(id: 8)
    source.preferences = {}
    Ticket::Article.records[source.id] = source
    article.in_reply_to = source.message_id
    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
    assert_equal '8', Wasalx::Client.calls.first.fetch(:payload).fetch(:reply_to_article_id)
    refute Wasalx::Client.calls.first.fetch(:payload).key?(:reply_to_message_id)
  end

  def test_delivery_quotes_exact_id_when_selected_article_has_no_message_id
    [1, 2].each do |sender_id|
      setup
      article, = register(FakeArticle.new)
      source = FakeArticle.new(id: 8)
      source.sender_id = sender_id
      source.message_id = nil
      source.preferences = {}
      Ticket::Article.records[source.id] = source
      article.in_reply_to = 'wasalx-article:8'
      Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
      assert_equal '8', Wasalx::Client.calls.first.fetch(:payload).fetch(:reply_to_article_id)
      assert_equal 1, Wasalx::Client.calls.length
    end
  end

  def test_explicit_article_identity_rejects_cross_ticket_private_system_wrong_type_and_self
    [[:ticket_id, 999], [:internal, true], [:sender_id, 3], [:type_id, 11], [:id, 9]].each do |field, value|
      setup
      article, = register(FakeArticle.new)
      source = field == :id ? article : FakeArticle.new(id: 8)
      source.public_send("#{field}=", value)
      Ticket::Article.records[source.id] = source
      article.in_reply_to = "wasalx-article:#{source.id}"
      assert_raises(Wasalx::Client::PermanentRequestFailed) do
        Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
      end
      assert_empty Wasalx::Client.calls
    end
  end

  def test_explicit_article_identity_rejects_missing_and_malformed_targets
    ['wasalx-article:404', 'wasalx-article:0', 'wasalx-article:08', 'wasalx-article:8x', "wasalx-article:8\n"].each do |target|
      setup
      article, = register(FakeArticle.new)
      article.in_reply_to = target
      assert_raises(Wasalx::Client::PermanentRequestFailed) do
        Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
      end
      assert_empty Wasalx::Client.calls
    end
  end

  def test_temporary_failures_are_observable_and_terminal_failure_note_is_unique
    article, ticket = register(FakeArticle.new)
    Wasalx::Client.error = Wasalx::Client::TemporaryRequestFailed.new('WasalX returned HTTP 503')
    service = Service::Ticket::Article::Type::WasalxGroupMessage::Deliver

    3.times do |attempt|
      assert_raises(Wasalx::Client::TemporaryRequestFailed) { service.execute(article_id: article.id) }
      assert_equal attempt + 1, article.preferences.fetch('delivery_retry')
      assert_equal 'FAILED_RETRYABLE', article.preferences.fetch('wasalx_delivery_state')
      assert_equal service::TEMPORARY_FAILURE_MESSAGE, article.preferences.fetch('delivery_status_message')
      assert_equal service::TEMPORARY_FAILURE_CODE, article.preferences.fetch('wasalx_delivery_error_code')
      assert_empty Ticket::Article.created_notes
    end
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { service.execute(article_id: article.id) }

    assert_equal 4, article.preferences.fetch('delivery_retry')
    assert_equal 'FAILED_TERMINAL', article.preferences.fetch('wasalx_delivery_state')
    assert_equal Service::Ticket::Article::Type::WasalxGroupMessage::Deliver::TERMINAL_FAILURE_MESSAGE,
                 article.preferences.fetch('delivery_status_message')
    assert_equal service::TERMINAL_FAILURE_CODE, article.preferences.fetch('wasalx_delivery_error_code')
    refute_includes article.preferences.fetch('delivery_status_message'), 'HTTP 503'
    assert_equal({ wasalx_delivery_status: 'FAILED_TERMINAL' }, ticket.updates.last)
    assert_equal 1, Ticket::Article.created_notes.length
    note = Ticket::Article.created_notes.first
    assert_equal true, note.fetch(:internal)
    assert_equal 'System', note.fetch(:sender).name
    assert_equal 'note', note.fetch(:type).name
    refute_includes note.fetch(:body), 'HTTP 503'
    assert_equal "#{service::TERMINAL_FAILURE_MESSAGE} (#{service::TERMINAL_FAILURE_CODE})", note.fetch(:body)

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { service.execute(article_id: article.id) }
    assert_equal 1, Ticket::Article.created_notes.length
  end

  def test_success_after_temporary_failure_clears_safe_failure_state
    article, = register(FakeArticle.new)
    service = Service::Ticket::Article::Type::WasalxGroupMessage::Deliver
    Wasalx::Client.error = Wasalx::Client::TemporaryRequestFailed.new('WasalX returned HTTP 503')

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { service.execute(article_id: article.id) }
    assert_equal service::TEMPORARY_FAILURE_CODE, article.preferences.fetch('wasalx_delivery_error_code')
    Wasalx::Client.error = nil
    service.execute(article_id: article.id)

    assert_nil article.preferences['delivery_status_message']
    assert_nil article.preferences['wasalx_delivery_error_code']
    assert_equal 'QUEUED', article.preferences.fetch('wasalx_delivery_state')
    assert_empty Ticket::Article.created_notes
    assert_equal [{ reset_user_id: true }, { reset_user_id: true }], Transaction.calls
  end

  def test_service_defensively_rejects_internal_articles_without_calling_wasalx
    article, ticket = register(FakeArticle.new.tap { |value| value.internal = true })
    service = Service::Ticket::Article::Type::WasalxGroupMessage::Deliver

    assert_raises(Wasalx::Client::PermanentRequestFailed) { service.execute(article_id: article.id) }
    assert_empty Wasalx::Client.calls
    assert_equal 'FAILED_TERMINAL', article.preferences.fetch('wasalx_delivery_state')
    assert_equal({ wasalx_delivery_status: 'FAILED_TERMINAL' }, ticket.updates.last)
    assert_equal 1, Ticket::Article.created_notes.length
  end

  def test_service_defensively_rejects_provider_origin_agent_articles
    article, = register(FakeArticle.new.tap { |value| value.preferences['wasalx_origin'] = 'provider' })
    service = Service::Ticket::Article::Type::WasalxGroupMessage::Deliver

    assert_raises(Wasalx::Client::PermanentRequestFailed) { service.execute(article_id: article.id) }
    assert_empty Wasalx::Client.calls
    assert_equal 'FAILED_TERMINAL', article.preferences.fetch('wasalx_delivery_state')
  end
end

# These tests execute the package-owned service against the existing in-process
# native model harness. Installed Rails/database transaction proof is separate.
load File.join(ROOT, 'zammad-package/app/services/service/ticket/wasalx_quoted_command.rb')
module Exceptions
  class Forbidden < StandardError; end unless const_defined?(:Forbidden)
end
class User; end unless defined?(User)
class UserInfo; end unless defined?(UserInfo)
module Wasalx::ServiceIdentity; end unless defined?(Wasalx::ServiceIdentity)

class QuotedCommandRuntimeContractTest < Minitest::Test
  EXECUTION_ID = '91000000-0000-4000-8000-000000000001'
  HASH = 'a' * 64
  CommandArticle = Struct.new(:id, :ticket_id, :internal, :preferences, :wasalx_operation_key, :body)
  CommandAgent = Struct.new(:active, :agent_permission, :groups) do
    def permissions?(name) = name == 'ticket.agent' && agent_permission
    def group_ids_access(name) = name == 'full' ? groups : []
  end
  class CommandTicket
    attr_accessor :state_id, :updated_at, :wasalx_correlation_status
    attr_reader :id, :group_id, :wasalx_connection_id, :wasalx_group_id, :updates
    attr_accessor :pending_articles
    def initialize
      @id, @group_id, @state_id = 42, 1, 2
      @wasalx_connection_id, @wasalx_group_id = 'connection-1', 'test-user-1675@example.test'
      @updated_at = Time.utc(2026, 10, 5, 12, 0, 0, 123_456)
      @pending_articles, @updates = [], []
    end
    def with_lock
      @locked = true
      yield
    ensure
      @locked = false
    end
    def wasalx_pending_close_articles(*) = pending_articles
    def owner_id = 77
    def reload = self
    def update!(attributes)
      raise 'native write outside ticket lock/transaction' unless @locked && Transaction.depth.to_i.positive?
      @updates << attributes
      @state_id = attributes.fetch(:state_id)
      @updated_at += 1
    end
  end

  def override(target, name, &body)
    previous = target.singleton_class.instance_methods(false).include?(name) ? target.method(name) : nil
    @restore << [target, name, previous]
    target.define_singleton_method(name, &body)
  end

  def setup
    @restore, @articles, @created, @user_queries = [], [], [], []
    @ticket = CommandTicket.new
    @agents = [CommandAgent.new(true, true, [1])]
    @service_user = Struct.new(:id) { def permissions?(name) = name == 'admin.system' }.new(77)
    # Machine authorization has its own real native/contract suite. This fixture
    # verifies the service forwards the authenticated native principal and token.
    principal = @service_user
    authenticated_token = Object.new
    override(UserInfo, :current_token) { authenticated_token }
    override(Wasalx::ServiceIdentity, :authorize!) do |actual_user, actual_token|
      raise Exceptions::Forbidden unless actual_user.equal?(principal) && actual_token.equal?(authenticated_token)
      true
    end
    @snapshot = {
      'tenant_id' => TENANT_ID, 'instance_id' => INSTANCE_ID,
      'ticket_id' => '42', 'execution_id' => EXECUTION_ID,
      'request_sha256' => HASH, 'native_action_state' => 'ATTEMPTED', 'effects_clear' => true,
      'connection_id' => 'connection-1', 'external_group_id' => 'test-user-1675@example.test', 'native_group_id' => '1',
      'expected_native_updated_at' => @ticket.updated_at.utc.iso8601(6),
      'expected_native_state_id' => '2', 'expected_native_article_id' => '9',
      'permission' => 'AGENTS', 'member_email' => 'agent@example.test',
      'command_text' => '/close', 'message_id' => 'provider-command-a', 'quoted_message_id' => 'selected-message',
      'participant_id' => '12025550135@c.us'
    }
    ENV['WASALX_TENANT_ID'], ENV['WASALX_ZAMMAD_INSTANCE_ID'] = TENANT_ID, INSTANCE_ID
    Transaction.calls, Transaction.depth, Transaction.after_execute = [], 0, nil
    snapshot = @snapshot
    override(Wasalx::Client, :get) { |path, scope:|
      expected_path = snapshot.key?('command_id') ? "/internal/v1/zammad/direct-customer-closes/#{EXECUTION_ID}" :
        "/internal/v1/zammad/quoted-commands/#{EXECUTION_ID}?denied_transcript=v1"
      raise 'unexpected admission request' unless path == expected_path && scope == 'zammad:ticket-state'
      snapshot.deep_dup
    }
    articles, created = @articles, @created
    override(Ticket::Article, :find_by) { |wasalx_operation_key:| articles.find { |a| a.wasalx_operation_key == wasalx_operation_key } }
    override(Ticket::Article, :where) { |ticket_id:|
      raise 'wrong ticket' unless ticket_id == 42
      Object.new.tap { |relation| relation.define_singleton_method(:maximum) { |name| raise 'unexpected maximum' unless name == :id; 9 } }
    }
    override(Ticket::Article, :create!) { |**attributes|
      raise 'receipt outside native transaction' unless Transaction.depth.to_i.positive?
      created << attributes
      articles << CommandArticle.new(10, attributes.fetch(:ticket_id), attributes.fetch(:internal),
        attributes.fetch(:preferences), attributes.fetch(:wasalx_operation_key), attributes.fetch(:body))
      articles.last
    }
    override(Ticket::State, :find_by!) { |name:| raise 'wrong state' unless name == 'closed'; Ticket::State::RECORDS.fetch(4) }
    override(Ticket::Article::Type, :lookup) { |name:| raise 'wrong article type' unless name == 'note'; Ticket::Article::Type.find_by(name: name) }
    override(Ticket::Article::Sender, :lookup) { |name:| raise 'wrong article sender' unless name == 'System'; Ticket::Article::Sender.find_by(name: name) }
    agents, queries = @agents, @user_queries
    override(User, :where) { |sql, email|
      queries << [sql, email]
      relation = Object.new
      relation.define_singleton_method(:where) { |active:| raise 'inactive identities admitted' unless active; self }
      relation.define_singleton_method(:limit) { |limit| raise 'ambiguity guard absent' unless limit == 2; self }
      relation.define_singleton_method(:to_a) { agents }
      relation
    }
  end

  def teardown
    @restore.reverse_each do |target, name, previous|
      previous ? target.define_singleton_method(name, previous) : target.singleton_class.remove_method(name)
    end
  end

  def service
    Service::Ticket::WasalxQuotedCommand.new(ticket: @ticket, execution_id: EXECUTION_ID, current_user: @service_user)
  end

  def assert_closed_once
    result = service.execute
    assert_equal 'SUCCEEDED', result.fetch('state')
    assert_equal 4, @ticket.state_id
    assert_equal 1, @ticket.updates.length
    assert_equal 1, @created.length
    assert_equal true, @created.first.fetch(:internal)
    assert_equal '/close', @created.first.fetch(:body)
    assert_equal 'provider-command-a', @created.first.fetch(:preferences).fetch('wasalx_external_message_id')
    assert_equal 'selected-message', @created.first.fetch(:preferences).fetch('wasalx_quoted_external_message_id')
    assert_equal '12025550135@c.us', @created.first.fetch(:preferences).fetch('wasalx_participant_id')
    assert_equal "ticket-command:#{EXECUTION_ID}", @created.first.fetch(:wasalx_operation_key)
    result
  end

  def test_quoted_command_agents_requires_actual_full_native_access
    assert_closed_once
    assert_equal [['LOWER(email) = ?', 'agent@example.test']], @user_queries
  end

  def test_quoted_command_agents_denies_missing_group_permission
    @agents.replace([CommandAgent.new(true, true, [2])])
    assert_raises(Exceptions::Forbidden) { service.execute }
    assert_empty @ticket.updates
    assert_empty @created
  end

  def test_quoted_command_specific_uses_backend_admission_without_agent_inference
    @snapshot['permission'] = 'SPECIFIC'
    @agents.clear
    assert_closed_once
    assert_empty @user_queries
  end

  def test_quoted_command_anyone_uses_scoped_service_admission
    @snapshot['permission'] = 'ANYONE'
    @agents.clear
    assert_closed_once
    assert_empty @user_queries
  end

  def test_quoted_command_activity_mismatch_stops_before_native_write
    @ticket.updated_at += 1
    assert_raises(ArgumentError) { service.execute }
    assert_empty @ticket.updates
    assert_empty @created
  end

  def test_quoted_command_duplicate_receipt_never_repeats_close
    first = assert_closed_once
    @snapshot['native_action_state'] = 'OUTCOME_UNKNOWN'
    assert_equal first, service.execute
    assert_equal first, service.reconcile
    assert_equal 1, @ticket.updates.length
    assert_equal 1, @created.length
  end

  def test_quoted_command_unknown_without_receipt_is_read_only_and_cannot_execute
    @snapshot['native_action_state'] = 'OUTCOME_UNKNOWN'
    assert_equal 'NO_RECEIPT', service.reconcile.fetch('state')
    assert_raises(Exceptions::Forbidden) { service.execute }
    assert_empty @ticket.updates
    assert_empty @created
  end

  def test_quoted_command_pending_agent_article_stops_close
    @ticket.pending_articles = [9]
    assert_raises(ArgumentError) { service.execute }
    assert_empty @ticket.updates
    assert_empty @created
  end

  def test_denied_command_records_bilingual_rejection_without_close_or_role_lookup
    @snapshot.merge!('disposition' => 'TRANSCRIPT_ONLY_DENIED', 'denied_transcript' => 'v1',
      'command_authorized' => false, 'plan' => { 'effects' => [] })
    @agents.clear
    first = service.execute
    assert_equal 'REJECTED', first.fetch('outcome')
    assert_equal 'TRANSCRIPT_ONLY_DENIED', first.fetch('disposition')
    assert first.key?('recorded_at')
    refute first.key?('closed_at')
    assert_equal 2, @ticket.state_id
    assert_empty @ticket.updates
    assert_empty @user_queries
    assert_equal 1, @created.length
    assert_match(%r{\A/close\n\nRejected: only tenant agents}, @created.first.fetch(:body))
    assert_includes @created.first.fetch(:body), 'تم الرفض'
    @snapshot['native_action_state'] = 'OUTCOME_UNKNOWN'
    assert_equal first, service.reconcile
    assert_equal first, service.execute
    assert_equal 1, @created.length
    @articles.first.body = '/close'
    assert_raises(ArgumentError) { service.reconcile }
  end

  def test_denied_command_unknown_capability_or_effect_cannot_execute
    @snapshot.merge!('disposition' => 'TRANSCRIPT_ONLY_DENIED', 'denied_transcript' => 'v2',
      'command_authorized' => false, 'plan' => { 'effects' => [] })
    assert_raises(ArgumentError) { service.execute }
    @snapshot['denied_transcript'] = 'v1'
    @snapshot['plan']['effects'] = [{ 'type' => 'close_ticket' }]
    assert_raises(ArgumentError) { service.execute }
    assert_empty @ticket.updates
    assert_empty @created
  end
end

# Package-owned behavior only; actual Rails row-lock/rollback qualification is separate.
load File.join(ROOT, 'zammad-package/app/services/service/ticket/wasalx_customer_close.rb')
class ZammadRuntimeContractTest
  def direct_reply_fixture
    article, ticket = register(FakeArticle.new)
    user = article.created_by
    user.define_singleton_method(:active) { true }
    user.define_singleton_method(:id) { 77 }
    user.define_singleton_method(:group_ids_access) { |permission| permission == 'full' ? [1] : [1, 2] }
    article.preferences = { 'wasalx_native_reply_intent_id' => 'untrusted', wasalx_native_reply_intent_id: 'untrusted' }
    lock_open = false
    ticket.define_singleton_method(:with_lock) { |&block| lock_open = true; block.call; lock_open = false }
    original_get, original_post = Wasalx::Client.method(:get), Wasalx::Client.method(:post)
    calls = []
    Wasalx::Client.define_singleton_method(:get) do |*args, **kwargs|
      raise 'preflight outside native ticket lock' unless lock_open
      { 'keep_open' => true }
    end
    Wasalx::Client.define_singleton_method(:post) do |path, payload, **kwargs|
      raise 'intent outside native ticket lock' unless lock_open
      calls << [path, payload, kwargs]
      { 'id' => payload.fetch(:operation_id), 'human_ownership_epoch' => 3 }
    end
    yield article, ticket, calls
  ensure
    Wasalx::Client.define_singleton_method(:get, original_get) if original_get
    Wasalx::Client.define_singleton_method(:post, original_post) if original_post
  end

  def test_direct_native_reply_reserves_inside_ticket_lock_and_stamps_only_trusted_marker
    direct_reply_fixture do |article, _ticket, calls|
      assert article.send(:ticket_article_preflight_wasalx_outbound)
      assert_equal 1, calls.length
      assert_equal '/internal/v1/zammad/outbound/native-intent', calls.first[0]
      assert_equal [1], calls.first[2].fetch(:actor).fetch(:group_ids)
      assert_equal false, calls.first[2].fetch(:actor).fetch(:group_admin)
      assert_equal calls.first[1].fetch(:operation_id), article.preferences.fetch('wasalx_native_reply_intent_id')
      refute article.preferences.key?(:wasalx_native_reply_intent_id)
      refute_equal 'untrusted', article.preferences.fetch('wasalx_native_reply_intent_id')
    end
  end

  def test_direct_native_reply_marker_is_not_preserved_on_noncommunicative_article
    article, = register(FakeArticle.new)
    article.internal = true
    article.preferences = { 'wasalx_native_reply_intent_id' => 'untrusted', wasalx_native_reply_intent_id: 'untrusted' }
    article.send(:ticket_article_preflight_wasalx_outbound)
    assert_empty article.preferences
    assert_empty Wasalx::Client.calls
  end

  def test_direct_outbound_payload_keeps_trusted_intent_for_durable_admission
    article, = register(FakeArticle.new)
    article.preferences['wasalx_native_reply_intent_id'] = '91000000-0000-4000-8000-000000000001'
    Service::Ticket::Article::Type::WasalxGroupMessage::Deliver.execute(article_id: article.id)
    assert_equal article.preferences['wasalx_native_reply_intent_id'], Wasalx::Client.calls.last.fetch(:payload).fetch(:native_reply_intent_id)
  end
end

class QuotedCommandRuntimeContractTest
  def customer_close_service
    @snapshot['command_id'] = EXECUTION_ID
    @snapshot['external_chat_id'] = @ticket.wasalx_group_id
    @snapshot['customer_id'] = '8'
    @snapshot['human_ownership_epoch'] = 3
    @snapshot['conversation_fencing_token'] = 11
    @ticket.define_singleton_method(:customer_id) { 8 }
    @ticket.define_singleton_method(:wasalx_bot_conversation) { 'true' }
    Service::Ticket::WasalxCustomerClose.new(ticket: @ticket, command_id: EXECUTION_ID, current_user: @service_user)
  end

  def test_customer_confirmation_closes_once_and_preserves_bound_receipt_on_unknown_reconciliation
    close = customer_close_service
    first = close.execute
    assert_equal 'SUCCEEDED', first.fetch('state')
    assert_equal 4, @ticket.state_id
    assert_equal 1, @ticket.updates.length
    assert_equal 1, @created.length
    assert_equal "direct-customer-close:#{EXECUTION_ID}", @created.first.fetch(:wasalx_operation_key)
    assert_equal '8', first.fetch('customer_id')
    assert_equal 3, first.fetch('human_ownership_epoch')
    @snapshot['native_action_state'] = 'OUTCOME_UNKNOWN'
    assert_equal first, close.execute
    assert_equal first, close.reconcile
    assert_equal 1, @ticket.updates.length
    assert_equal 1, @created.length
    refute @ticket.instance_variable_defined?(:@wasalx_customer_close_command_id)
  end

  def test_customer_unknown_without_receipt_never_repeats_native_close
    close = customer_close_service
    @snapshot['native_action_state'] = 'OUTCOME_UNKNOWN'
    assert_equal 'NO_RECEIPT', close.reconcile.fetch('state')
    assert_raises(Exceptions::Forbidden) { close.execute }
    assert_empty @created
    assert_empty @ticket.updates
  end

  def test_customer_close_cannot_close_foreign_or_changed_direct_customer
    close = customer_close_service
    @snapshot['customer_id'] = '9'
    assert_raises(ArgumentError) { close.execute }
    assert_empty @created
    assert_empty @ticket.updates
  end

  def test_customer_close_holds_pending_reply_without_creating_system_receipt
    close = customer_close_service
    @ticket.pending_articles = [9]
    assert_raises(ArgumentError) { close.execute }
    assert_empty @created
    assert_empty @ticket.updates
  end

  def test_already_closed_native_ticket_cannot_fabricate_customer_confirmed_receipt
    close = customer_close_service
    @ticket.state_id = 4
    @snapshot['expected_native_state_id'] = '4'
    assert_raises(ArgumentError) { close.execute }
    assert_empty @created
    assert_empty @ticket.updates
  end
end
