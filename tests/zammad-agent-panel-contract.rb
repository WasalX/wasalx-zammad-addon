# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX

require 'minitest/autorun'
require 'digest'
require 'monitor'

class Hash
  def to_query; URI.encode_www_form(self); end

  def with_indifferent_access
    transform_keys(&:to_s)
  end
end

ROOT = File.expand_path('..', __dir__)

module ActiveRecord
  class RecordNotFound < StandardError; end
  class RecordNotUnique < StandardError; end
  class RecordInvalid < StandardError; end
end

module ActionController
  class BadRequest < StandardError; end
  class Parameters < Hash; end
end

module ActiveSupport
  module SecurityUtils
    class << self
      attr_accessor :comparisons

      def secure_compare(left, right)
        self.comparisons += 1
        left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
      end
    end
  end
end

module Exceptions
  class Forbidden < StandardError; end
  class ApplicationModel < StandardError; end
end

module Transaction
  def self.execute
    (@lock ||= Monitor.new).synchronize { yield }
  end
end

module Service
  class Base; end

  module Ticket; end
end

class ApplicationController
  class << self
    attr_reader :prepended_before_actions
    attr_reader :request_failure_handler

    def rescue_from(error_class, with:)
      @request_failure_handler = [error_class, with]
    end

    def prepend_before_action(*actions)
      @prepended_before_actions = actions
    end
  end

  attr_accessor :params, :deny_authorization
  attr_reader :current_user, :authorization, :rendered, :rendered_status

  def current_user=(actor)
    @current_user = actor
    User.records[actor.id] = actor if defined?(User) && User.records && actor&.id
  end

  def authorize!(record, policy)
    @authorization = [record, policy]
    raise Exceptions::Forbidden if deny_authorization
  end

  def render(json:, status: nil)
    @rendered = json
    @rendered_status = status
  end

  def head(status)
    @rendered_status = status
  end

  def __(value)
    value
  end
end

class Translation
  class << self
    attr_accessor :synced_locales, :sync_user_id

    def sync_locale_from_po(locale)
      self.sync_user_id = UserInfo.current_user_id
      (@synced_locales ||= []) << locale
    end

    def translate(locale, source)
      catalogue = File.read(File.join(ROOT, "zammad-package/i18n/wasalx.#{locale}.po"), encoding: 'UTF-8')
      catalogue[/^msgid "#{Regexp.escape(source)}"\r?\nmsgstr "([^"]+)"/, 1] || source
    end
  end
end

class UserInfo
  def self.current_user_id; Thread.current[:native_test_user_id]; end
  def self.current_user_id=(id); Thread.current[:native_test_user_id] = id; end

  def self.with_user_id(id)
    prior = current_user_id
    self.current_user_id = id
    yield
  ensure
    self.current_user_id = prior
  end
end

class Setting
  class << self
    attr_accessor :values

    def exists?(name:)
      values.key?(name)
    end

    def get(name)
      values.fetch(name)
    end

    def set(name, value)
      values[name] = value
    end
  end
end

class Object
  def __(value); value; end

  def present?
    !respond_to?(:empty?) || !empty?
  end

  def blank?
    !present?
  end

  def presence
    present? ? self : nil
  end
end

class NilClass
  def present?
    false
  end
end

class Array
  def index_by
    each_with_object({}) { |item, result| result[yield(item)] = item }
  end
end

module Api
  module V1; end
end

class Ticket
  attr_accessor :id, :number, :title, :group_id, :customer_id, :wasalx_connection_id,
                :wasalx_group_id, :wasalx_group_name, :wasalx_provider,
                :wasalx_source_message_id, :wasalx_latest_external_message_id,
                :created_by_id, :updated_by_id, :screen

  class << self
    attr_accessor :record, :created_records, :workflow_guard

    def transaction(**, &block); Transaction.execute(&block); end
    def connection; self; end
    def execute(_query); end

    def find(id)
      value = [record, *created_records].compact.find { |candidate| candidate.id.to_s == id.to_s }
      raise ActiveRecord::RecordNotFound if !value

      value
    end

    def find_by(number:)
      [record, *created_records].compact.find { |candidate| candidate.number.to_s == number.to_s }
    end
  end

  def initialize(**attributes)
    attributes.each { |name, value| public_send("#{name}=", value) if respond_to?("#{name}=") }
  end

  def save!
    self.class.workflow_guard&.call(self, :create, {})
    self.id ||= 100 + self.class.created_records.length
    self.number ||= (10_000 + id).to_s
    self.class.created_records << self
    self
  end

  def update!(attributes)
    attributes.each { |name, value| public_send("#{name}=", value) }
    self
  end

  def lock!; self; end

  def with_lock
    yield
  end
end

class Group
  class << self
    attr_accessor :record

    def find_by(id:, active:)
      record if active && record&.id.to_s == id.to_s
    end
  end
end

TestStoreItem = Struct.new(:id, :filename, :file_size, :content, :preferences, :object, :o_id, :created_by_id,
                           :created_at, keyword_init: true) do
  alias size file_size

  def touch
    self
  end
end

class Store
  class << self
    def transaction(&block); Transaction.execute(&block); end
    def connection; Ticket.connection; end
    def exists?(id); records.any? { |row| row.id.to_s == id.to_s }; end
    attr_reader :records

    def reset!
      @records = []
      @next_id = 1000
    end

    def create!(attributes)
      item = TestStoreItem.new(id: @next_id, filename: attributes.fetch(:filename),
                               file_size: attributes.fetch(:data).bytesize, content: attributes.fetch(:data),
                               preferences: attributes.fetch(:preferences), object: attributes.fetch(:object),
                               o_id: attributes.fetch(:o_id), created_by_id: attributes[:created_by_id])
      @next_id += 1
      @records << item
      item
    end

    def list(object:, o_id:, created_by_id: nil)
      @records.select do |item|
        item.object == object && item.o_id == o_id && (!created_by_id || item.created_by_id == created_by_id)
      end
    end

    def remove_item(id)
      index = @records.index { |item| item.id.to_s == id.to_s }
      raise ActiveRecord::RecordNotFound if !index

      @records.delete_at(index)
    end
  end
end

class UploadCache
  class << self
    attr_reader :destroyed

    def reset!
      @items = {}
      @destroyed = []
    end

    def seed(id, items)
      items.each { |item| item.created_by_id ||= 17 }
      @items[id] = items
    end

    def items(id)
      @items.fetch(id, [])
    end
  end

  def initialize(id)
    @id = id
  end

  def attachments(created_by_id: UserInfo.current_user_id)
    self.class.items(@id).select { |item| !created_by_id || item.created_by_id == created_by_id }
  end

  def destroy
    self.class.destroyed << @id
  end
end

class Ticket::Article
  Scope = Struct.new(:rows) do
    def order(**) = self
    def limit(count) = rows.first(count)
  end

  class << self
    attr_accessor :created_articles, :reply_articles

    def where(ticket_id:) = Scope.new(reply_articles.select { |article| article.ticket_id == ticket_id })
    def find(id) = reply_articles.find { |article| article.id == id } || raise(ActiveRecord::RecordNotFound)

    def find_by(wasalx_operation_key: nil, ticket_id: nil, id: nil, message_id: nil)
      return created_articles.find { |article|
        article[:wasalx_operation_key] == wasalx_operation_key
      } if wasalx_operation_key

      created = created_articles.find { |article| article.ticket_id == ticket_id && article.id == id } if id
      return created if created

      reply_articles.find { |article|
        article.ticket_id == ticket_id && (id ? article.id == id : article.message_id == message_id)
      }
    end

    def find_by!(**values)
      find_by(**values) || raise(ActiveRecord::RecordNotFound)
    end

    def create!(attributes)
      article = attributes.merge(id: created_articles.length + 1)
      article.define_singleton_method(:wasalx_operation_key) { self[:wasalx_operation_key] }
      article.define_singleton_method(:created_by_id) { self[:created_by_id] }
      article.define_singleton_method(:id) { self[:id] }
      article.define_singleton_method(:ticket_id) { self[:ticket_id] }
      article.define_singleton_method(:ticket) { Ticket.find(self[:ticket_id]) }
      created_articles << article
      article
    end
  end
end

class Ticket::ArticlePolicy
  def initialize(actor, _article) = @actor = actor
  def show? = @actor.permissions?('ticket.agent')
end

class Ticket::Article::Sender
  def self.lookup(id:)
    name = { 1 => 'Agent', 2 => 'Customer', 3 => 'System' }[id]
    Struct.new(:name).new(name) if name
  end

  def self.find_by!(name:)
    name
  end
end

class Ticket::Article::Type
  def self.lookup(id:)
    name = { 10 => 'wasalx group message', 11 => 'note' }[id]
    Struct.new(:name).new(name) if name
  end

  def self.find_by!(name:)
    name
  end
end

class User
  attr_accessor :id, :login, :firstname, :mobile, :updated_by_id

  class << self
    attr_accessor :records

    def transaction(**, &block); Transaction.execute(&block); end

    def find(id)
      records.fetch(Integer(id))
    rescue KeyError
      raise ActiveRecord::RecordNotFound
    end

    def find_by(login:)
      records.values.find { |user| user.login == login }
    end

    def find_by!(login:)
      find_by(login: login) || raise(ActiveRecord::RecordNotFound)
    end

    def create!(attributes)
      user = new(**attributes)
      records[user.id] = user
      user
    end
  end

  def initialize(id: nil, login:, firstname:, mobile: nil, **_attributes)
    @id = id || ((self.class.records.keys.max || 100) + 1)
    @login = login
    @firstname = firstname
    @mobile = mobile
  end

  def update!(attributes)
    attributes.each { |name, value| public_send("#{name}=", value) }
    self
  end
end

FakeUser = Struct.new(:permission_names, :id, :group_ids) do
  attr_accessor :denied_policies

  def active; true; end
  def login; "native-#{id}"; end

  def permissions?(name)
    permission_names.any? { |held| name == held || name.start_with?("#{held}.") }
  end

  def group_ids_access(_permission)
    group_ids || []
  end

  def fullname
    'Agent One'
  end

  def firstname
    'Agent'
  end

  def lastname
    'One'
  end
end

FakeTicket = Struct.new(
  :id, :number, :wasalx_reference, :wasalx_group_id, :wasalx_group_name,
  :wasalx_connection_id, :wasalx_provider, :wasalx_correlation_status,
  :wasalx_rule_version, :wasalx_delivery_status, :wasalx_bot_state, :wasalx_source_message_id,
  :wasalx_latest_external_message_id, :updated_by_id, :articles, :screen, :group_id, :title,
  keyword_init: true
) do
  def articles
    self[:articles] || []
  end

  def update!(attributes)
    Ticket.workflow_guard&.call(self, :update, attributes)
    attributes.each { |name, value| public_send("#{name}=", value) }
    self
  end

  def lock!; self; end

  def with_lock
    (@lock ||= Mutex.new).synchronize { yield }
  end
end

load File.join(ROOT, 'zammad-package/lib/wasalx/client.rb')

class Wasalx::Client
  class << self
    attr_accessor :test_response, :test_error, :post_results, :get_results, :download_result
    attr_reader :get_calls, :post_calls, :download_calls

    def get(path, scope:, **)
      @get_calls ||= []
      @get_calls << { path: path, scope: scope }
      raise test_error if test_error

      if path.start_with?('/internal/v1/zammad/group-workspace/groups?')
        selected = URI.decode_www_form(URI.parse(path).query).to_h.fetch('selected')
        return { 'items' => [{ 'id' => selected }] }
      end
      result = get_results&.shift
      raise result if result.is_a?(Exception)
      return result if result

      if path.include?('/group-workspace/tickets/')
        {
          'group_id' => '40000000-0000-4000-8000-000000000004',
          'message_id' => '50000000-0000-4000-8000-000000000005',
          'sender_name' => 'Customer One', 'sender_phone' => '+12025550184', 'from_me' => false
        }
      else
        test_response
      end
    end

    def download(url, maximum_bytes, expected_content_type:, expected_sha256:)
      @download_calls ||= []
      @download_calls << { url: url, maximum_bytes: maximum_bytes, expected_content_type: expected_content_type,
                           expected_sha256: expected_sha256 }
      download_result
    end

    def post(path, payload, scope:, actor: nil)
      @post_calls ||= []
      @post_calls << { path: path, payload: payload, scope: scope, actor: actor }
      result = post_results&.shift
      raise result if result.is_a?(Exception)
      return result if result

      { 'id' => payload.fetch(:delivery_id), 'state' => 'QUEUED', 'duplicate' => false }
    end

    def reset_panel_test!
      @get_calls = []
      @post_calls = []
      @download_calls = []
      @post_results = []
      @get_results = []
      @download_result = nil
      @test_error = nil
      @test_response = {
        'ticket_id' => '42',
        'connection_id' => '12000000-0000-4000-8000-000000000001',
        'provider' => 'WAHA',
        'connection_state' => 'WORKING',
        'binding_state' => 'ACTIVE',
        'group_name' => "Riyadh\u0000 Operations",
        'correlation_state' => 'OPEN',
        'last_heartbeat_at' => '2026-08-09T20:00:00.000Z',
        'last_provider_event_at' => '2026-08-09T20:01:00.000Z',
        'delivery_id' => '30000000-0000-4000-8000-000000000003',
        'zammad_article_id' => '9',
        'delivery_state' => 'DELIVERED',
        'delivery_updated_at' => '2026-08-09T20:02:00.000Z',
        'delivery_retry_allowed' => false,
        'delivery_retry_requires_confirmation' => false
      }
    end
  end
end

load File.join(ROOT, 'zammad-package/app/services/service/ticket/wasalx_panel.rb')
load File.join(ROOT, 'zammad-package/app/services/service/ticket/wasalx_reply_context.rb')
class TicketPolicy
  def initialize(actor, ticket); @actor, @ticket = actor, ticket; end
  def agent_read_access?; permitted?(:agent_read_access?); end
  def agent_update_access?; permitted?(:agent_update_access?); end
  def create?; permitted?(:create?); end

  private

  def permitted?(policy)
    @actor.permissions?('ticket.agent') && !Array(@actor.denied_policies).include?(policy)
  end
end

class WasalxMembership
  def self.find_by(**_values); nil; end
end

class WasalxTicketOperation
  Row = Struct.new(:operation_id, :portal_user_id, :native_user_id, :ticket_id, :kind, :request_sha256, :result,
                   keyword_init: true)
  class << self; attr_accessor :records; end
  def self.find_by(operation_id:); records[operation_id]; end

  def self.create!(**values)
    raise ActiveRecord::RecordNotUnique if records.key?(values[:operation_id])

    values[:result] = JSON.parse(JSON.generate(values[:result]))
    records[values[:operation_id]] = Row.new(**values)
  end
end

module Wasalx::ServiceIdentity
  def self.digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end
  def self.automation?(actor); actor.permission_names.include?('wasalx_service'); end
end

module Wasalx::MembershipAccess
  def self.check!(actor); raise Exceptions::Forbidden unless actor.active; end
end

module CreatesTicketArticles; end
load File.join(ROOT, 'zammad-package/app/controllers/api/v1/wasalx_controller.rb')
load File.join(ROOT, 'zammad-package/app/controllers/api/v1/wasalx_portal_workspace_controller.rb')
load File.join(ROOT, 'zammad-package/db/addon/wasalx/202608240008_enable_wasalx_modern_desktop_ui.rb')
load File.join(ROOT, 'zammad-package/db/addon/wasalx/202610050016_sync_wasalx_reply_preview_translations.rb')
load File.join(ROOT, 'zammad-package/db/addon/wasalx/202610180007_sync_wasalx_attachment_translation.rb')
load File.join(ROOT, 'zammad-package/db/addon/wasalx/202611240001_sync_wasalx_ticket_template_translations.rb')

module Validations
  class TicketArticleValidator
    class Default
      attr_reader :record

      def initialize(record)
        @record = record
      end

      def validate_body
        record.errors << :body_required if record.body.blank?
      end
    end
  end
end

load File.join(ROOT, 'zammad-package/lib/validations/ticket_article_validator/wasalx_group_message.rb')

class ZammadAgentPanelContractTest < Minitest::Test
  def test_portal_article_writer_uses_the_workspace_locale_only_for_attachment_only_notes_and_email
    Setting.set('locale_default', 'ar')
    writer = Api::V1::WasalxPortalWorkspaceController::ArticleWriter.new(nil)
    writer.define_singleton_method(:article_create) { |_ticket, attributes| attributes }

    %w[note email].each do |type|
      attributes = { type: type, body: '', form_id: 'verified-upload-cache' }
      assert_equal attributes.transform_keys(&:to_s).merge('body' => 'مرفق'), writer.call(nil, attributes)
      assert_equal 'Draft text', writer.call(nil, attributes.merge(body: 'Draft text')).fetch('body')
      assert_equal '', writer.call(nil, attributes.merge(form_id: nil)).fetch('body')
    end

    whatsapp = { type: 'wasalx group message', body: '', form_id: 'verified-upload-cache' }
    assert_equal whatsapp.transform_keys(&:to_s), writer.call(nil, whatsapp)
  end

  def test_wasalx_group_message_requires_body_or_a_native_attachment
    backend = Validations::TicketArticleValidator::WasalxGroupMessage
    assert_equal ['wasalx group message'], backend::MATCHING_TYPES

    record = Struct.new(:body, :attachments, :errors).new('', [], [])
    backend.new(record).validate_body
    assert_equal [:body_required], record.errors
    record.errors.clear

    record.instance_variable_set(:@attachments_buffer, [{}])
    backend.new(record).validate_body
    assert_empty record.errors

    record.instance_variable_set(:@attachments_buffer, [])
    record.attachments = [Object.new]
    backend.new(record).validate_body
    assert_empty record.errors
    assert_equal '', record.body
  end

  def test_attachment_translation_migration_syncs_arabic_without_changing_the_actor
    Translation.synced_locales = []
    UserInfo.with_user_id(17) do
      SyncWasalxAttachmentTranslation.up
      assert_equal 17, UserInfo.current_user_id
    end
    assert_equal ['ar'], Translation.synced_locales
  end

  def test_portal_article_preview_ends_on_a_grapheme_boundary
    article_type = Struct.new(:name).new('note')
    article_class = Struct.new(:id, :ticket_id, :body, :content_type, :internal, :from, :sender,
                               :type, :preferences, :created_at, :attachments, keyword_init: true)
    Ticket.record = Ticket.new(id: 42)
    controller = Api::V1::WasalxPortalWorkspaceController.new
    controller.instance_variable_set(:@actor, FakeUser.new(%w[ticket.agent], 77, [4]))
    prefix = 'x' * 49_999

    [
      [prefix + '👍🏽' + 'tail', prefix],
      [prefix + 'بِ' + 'tail', prefix],
      ['x' * 49_998 + '👍🏽' + 'tail', 'x' * 49_998 + '👍🏽'],
      [prefix + 'x', prefix + 'x']
    ].each do |body, expected|
      Ticket::Article.reply_articles = [article_class.new(id: 8, ticket_id: 42, body: body,
                                                          content_type: 'text/plain', internal: false, from: 'Agent',
                                                          sender: Ticket::Article::Sender.lookup(id: 1),
                                                          type: article_type, preferences: {},
                                                          created_at: Time.utc(2026, 1, 1), attachments: [])]
      controller.instance_variable_set(:@input, { 'ticket_id' => '42' })
      preview = controller.send(:articles).fetch(:items).fetch(0)

      actual = preview.fetch(:body)
      assert actual == expected,
             "Expected #{expected.length} codepoints, got #{actual.length} ending in #{actual[-8, 8].inspect}"
      assert_equal body.length, preview.fetch(:total_characters)
      assert_equal expected == body, preview.fetch(:body_complete)
      assert_equal Digest::SHA256.hexdigest(body), preview.fetch(:body_sha256)
      next if preview.fetch(:body_complete)

      controller.instance_variable_set(:@input, { 'ticket_id' => '42', 'article_id' => '8',
                                                  'offset' => actual.length,
                                                  'expected_sha256' => preview.fetch(:body_sha256) })
      remainder = controller.send(:article_content)
      assert body == actual + remainder.fetch(:body), 'Full article must resume from the end of the preview'
    end
  end

  def reply_preview_controller(**overrides)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 77, [4])
    controller.params = { ticket_id: '42', body: 'مرحبا', internal: false, has_attachments: false }.merge(overrides)
    Wasalx::Client.post_results = [{ 'text' => 'REF123 مرحبا', 'replyToMessageId' => 'provider-8' }]
    controller
  end

  def reply_preview_article(**overrides)
    Struct.new(:id, :ticket_id, :message_id, :internal, :type_id, :sender_id, keyword_init: true).new(
      **{ id: 8, ticket_id: 42, message_id: nil, internal: false, type_id: 10, sender_id: 2 }.merge(overrides)
    )
  end

  def test_reply_preview_is_read_only_and_uses_authorized_ticket_metadata
    source = reply_preview_article
    Ticket::Article.reply_articles = [source]
    controller = reply_preview_controller(in_reply_to: 'wasalx-article:8', tenant_id: 'untrusted',
                                          connection_id: 'untrusted', group_id: 'untrusted', agent: { id: '99' })
    snapshot = Marshal.dump([Ticket.record, Ticket::Article.reply_articles.map(&:to_h),
                             Ticket::Article.created_articles, Store.records, UploadCache.destroyed])
    controller.reply_preview
    assert_equal snapshot,
                 Marshal.dump([Ticket.record, Ticket::Article.reply_articles.map(&:to_h), Ticket::Article.created_articles,
                               Store.records, UploadCache.destroyed])
    assert_equal [Ticket.record, :agent_update_access?], controller.authorization
    assert_equal 1, Wasalx::Client.post_calls.length
    assert_empty Wasalx::Client.get_calls
    call = Wasalx::Client.post_calls.first
    assert_equal '/internal/v1/zammad/reply-preview', call[:path]
    assert_equal 'zammad:outbound', call[:scope]
    assert_equal({ user_id: 77, group_ids: [4], group_admin: false }, call[:actor])
    assert_equal({ tenant_id: ENV.fetch('WASALX_TENANT_ID'), connection_id: Ticket.record.wasalx_connection_id,
                   group_id: Ticket.record.wasalx_group_id, ticket_id: 42, body: 'مرحبا', reply_to_article_id: '8',
                   agent: { id: '77', display_name: 'Agent One' }, has_attachments: false, internal: false },
                 call[:payload])
    assert_equal({ 'text' => 'REF123 مرحبا', 'replyToMessageId' => 'provider-8' }, controller.rendered)
    assert_nil controller.rendered_status
  end

  def test_reply_preview_rejects_non_agents_and_denied_ticket_access_before_request
    controller = reply_preview_controller
    controller.current_user = FakeUser.new([], 88, [])
    assert_raises(Exceptions::Forbidden) { controller.reply_preview }
    assert_nil controller.authorization
    controller = reply_preview_controller
    controller.deny_authorization = true
    assert_raises(Exceptions::Forbidden) { controller.reply_preview }
    assert_equal [Ticket.record, :agent_update_access?], controller.authorization
    assert_empty Wasalx::Client.post_calls
  end

  def ticket_template_controller(get:, actor: FakeUser.new(%w[ticket.agent], 77, [4]))
    controller = Api::V1::WasalxController.new
    controller.current_user = actor
    request = Object.new
    request.define_singleton_method(:get?) { get }
    controller.define_singleton_method(:request) { request }
    input = ActionController::Parameters[
      request_token: '44000000-0000-4000-8000-000000000004', template_id: '341',
      template_sha256: 'a' * 64, parameters: ['42']
    ]
    controller.params = { ticket_id: '42', tenant_id: 'untrusted', connection_id: 'untrusted', group_id: 'untrusted',
                          input: input }
    controller
  end

  def test_ticket_template_catalog_and_send_use_native_ticket_and_agent
    Ticket.record.wasalx_provider = 'META'
    Ticket.record.wasalx_bot_state = 'HUMAN'
    expected_target = { tenant_id: ENV.fetch('WASALX_TENANT_ID'), ticket_id: 42,
                        connection_id: Ticket.record.wasalx_connection_id, group_id: Ticket.record.wasalx_group_id }
    catalog = { 'window' => 'CLOSED', 'templates' => [] }
    delivery = { 'id' => '45000000-0000-4000-8000-000000000005', 'state' => 'QUEUED' }
    recovery = ticket_template_controller(get: true)
    recovery.params[:recovery] = '1'
    recovery.ticket_templates
    scope = recovery.rendered.fetch(:scope)
    assert_match(/\A[a-f0-9]{64}\z/, scope)
    different_agent = ticket_template_controller(get: true, actor: FakeUser.new(%w[ticket.agent], 78, [4]))
    different_agent.params[:recovery] = '1'
    different_agent.ticket_templates
    refute_equal scope, different_agent.rendered.fetch(:scope)
    Wasalx::Client.post_results = [catalog, delivery, { 'delivery' => delivery }]

    [[true, 'catalog', :ok, catalog], [false, 'send', :accepted, delivery]].each do |get, path, status, response|
      controller = ticket_template_controller(get: get)
      controller.params[:input][:scope] = scope
      controller.ticket_templates
      assert_equal [Ticket.record, :agent_update_access?], controller.authorization
      assert_equal({ path: "/internal/v1/zammad/ticket-templates/#{path}", scope: 'zammad:outbound',
                     actor: { user_id: 77, group_ids: [4], group_admin: false },
                     payload: get ? expected_target : expected_target.merge(controller.params[:input].except(:scope)) },
                   Wasalx::Client.post_calls.last)
      assert_equal status, controller.rendered_status
      assert_equal response, controller.rendered
    end
    tracker = ticket_template_controller(get: true)
    token = tracker.params[:input][:request_token]
    tracker.params.merge!(scope: scope, request_token: token, delivery_id: delivery.fetch('id'))
    Ticket.record.wasalx_bot_state = 'RESOLVED'
    tracker.ticket_templates
    assert_equal({ path: '/internal/v1/zammad/ticket-templates/status', scope: 'zammad:outbound',
                   actor: { user_id: 77, group_ids: [4], group_admin: false },
                   payload: expected_target.merge(request_token: token, delivery_id: delivery.fetch('id')) },
                 Wasalx::Client.post_calls.last)
    assert_equal({ 'delivery' => delivery }, tracker.rendered)
    Ticket.record.wasalx_group_id = 'changed-target'
    assert_raises(Exceptions::Forbidden) { tracker.ticket_templates }
    assert_equal 3, ActiveSupport::SecurityUtils.comparisons
    assert_equal 3, Wasalx::Client.post_calls.length
    assert_empty Ticket::Article.created_articles
  end

  def test_ticket_templates_require_an_active_human_agent_with_full_ticket_access
    Ticket.record.wasalx_provider = 'META'
    Ticket.record.wasalx_bot_state = 'HUMAN'
    inactive = FakeUser.new(%w[ticket.agent], 81, [4])
    inactive.define_singleton_method(:active) { false }
    [true, false].each do |get|
      rejected = [FakeUser.new([], 78, [4]), FakeUser.new(%w[ticket.agent], 79, [9]),
                  FakeUser.new(%w[ticket.agent wasalx_service], 80, [4]), inactive]
      rejected.each do |actor|
        assert_raises(Exceptions::Forbidden) { ticket_template_controller(get: get, actor: actor).ticket_templates }
      end
      controller = ticket_template_controller(get: get)
      controller.deny_authorization = true
      assert_raises(Exceptions::Forbidden) { controller.ticket_templates }
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_ticket_template_catalog_and_send_refuse_ineligible_tickets
    [%w[WAHA HUMAN], %w[META BOT]].each do |provider, state|
      Ticket.record.wasalx_provider = provider
      Ticket.record.wasalx_bot_state = state
      [true, false].each do |get|
        assert_raises(ActiveRecord::RecordNotFound) { ticket_template_controller(get: get).ticket_templates }
      end
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_ticket_template_send_refuses_mismatched_or_malformed_scope
    valid_scope = ticket_template_scope
    ['0' * valid_scope.length, [], nil].each do |scope|
      controller = ticket_template_controller(get: false)
      controller.params[:input][:scope] = scope
      assert_raises(Exceptions::Forbidden) { controller.ticket_templates }
    end
    assert_equal 1, ActiveSupport::SecurityUtils.comparisons
    assert_empty Wasalx::Client.post_calls
  end

  def test_ticket_template_send_refuses_invalid_selection_before_forwarding
    scope = ticket_template_scope
    controller = ticket_template_controller(get: false)
    controller.params[:input] = 'invalid'
    assert_raises(ActionController::BadRequest) { controller.ticket_templates }

    [
      { template_id: 341 }, { template_id: '' }, { template_id: '3x' }, { template_id: '1' * 33 },
      { template_sha256: [] }, { template_sha256: 'a' * 63 }, { template_sha256: 'G' * 64 },
      { parameters: nil }, { parameters: '42' }, { parameters: [42] }, { parameters: ['42'] * 21 },
      { parameters: [''] }, { parameters: ["\u00a042"] }, { parameters: ["4\n2"] },
      { parameters: ['a' * 1025] }, { parameters: ['界' * 1024] * 4 }
    ].each do |overrides|
      controller = ticket_template_controller(get: false)
      controller.params[:input].merge!(scope: scope, **overrides)
      assert_raises(ActionController::BadRequest, overrides.keys.join(', ')) { controller.ticket_templates }
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_ticket_template_send_passes_valid_parameter_boundaries
    scope = ticket_template_scope
    [[], ['界' * 1024] + ['42'] * 19].each do |parameters|
      controller = ticket_template_controller(get: false)
      controller.params[:input].merge!(scope: scope, template_id: '1' * 32, parameters: parameters)
      Wasalx::Client.post_results = [{ 'state' => 'QUEUED' }]
      controller.ticket_templates
      assert_equal parameters, Wasalx::Client.post_calls.last.dig(:payload, :parameters)
      assert_equal :accepted, controller.rendered_status
    end
  end

  def test_ticket_template_send_maps_platform_errors_without_exposing_details
    scope = ticket_template_scope
    {
      400 => :bad_request, 401 => :forbidden, 403 => :forbidden, 404 => :not_found,
      409 => :conflict, 429 => :service_unavailable, nil => :service_unavailable
    }.each do |upstream, response|
      controller = ticket_template_controller(get: false)
      controller.params[:input][:scope] = scope
      Wasalx::Client.post_results = [Wasalx::Client::RequestFailed.new('upstream details', http_status: upstream)]
      controller.ticket_templates
      assert_equal response, controller.rendered_status
      assert_nil controller.rendered
    end
  end

  def ticket_template_scope
    Ticket.record.wasalx_provider = 'META'
    Ticket.record.wasalx_bot_state = 'HUMAN'
    controller = ticket_template_controller(get: true)
    controller.params[:recovery] = '1'
    controller.ticket_templates
    controller.rendered.fetch(:scope)
  end

  def test_reply_preview_forwards_only_a_boolean_restored_draft_signal_without_mutation
    [true, false].each do |restored|
      Wasalx::Client.reset_panel_test!
      controller = reply_preview_controller(restored_draft: restored)
      snapshot = Marshal.dump([Ticket.record, Ticket::Article.created_articles, Store.records])
      controller.reply_preview
      assert_equal restored, Wasalx::Client.post_calls.first.dig(:payload, :restored_draft)
      assert_equal snapshot, Marshal.dump([Ticket.record, Ticket::Article.created_articles, Store.records])
    end
  end

  def test_reply_preview_rejects_invalid_restored_draft_signal_before_source_request
    [nil, 'true', 1, {}].each do |restored|
      controller = reply_preview_controller(restored_draft: restored)
      assert_raises(ActionController::BadRequest) { controller.reply_preview }
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_reply_preview_strictly_rejects_private_and_invalid_drafts
    [{ internal: true }, { internal: nil }, { internal: 'false' }, { body: nil }, { body: [] },
     { body: '' }, { body: ' ' }, { body: 'x' * 4097 }, { body: "hidden\u0000message" },
     { has_attachments: nil }, { has_attachments: 'true' }].each do |values|
      assert_raises(ActionController::BadRequest, values.inspect) { reply_preview_controller(**values).reply_preview }
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_reply_preview_allows_attachment_only_and_bounded_arabic_without_normalizing_draft
    ['', "مرحبا\nبكم"].each do |body|
      controller = reply_preview_controller(body: body, has_attachments: true)
      controller.reply_preview
      assert_equal body, Wasalx::Client.post_calls.last.dig(:payload, :body)
      assert_equal true, Wasalx::Client.post_calls.last.dig(:payload, :has_attachments)
      refute Wasalx::Client.post_calls.last[:payload].key?(:reply_to_article_id)
    end
    assert_empty Store.records
    assert_empty Ticket::Article.created_articles
  end

  def test_reply_preview_uses_same_strict_public_article_resolution_as_delivery
    [1, 2].each do |sender|
      [nil, 'zammad-source-8'].each do |message_id|
        Ticket::Article.reply_articles = [reply_preview_article(sender_id: sender, message_id: message_id)]
        controller = reply_preview_controller(in_reply_to: message_id || 'wasalx-article:8')
        controller.reply_preview
        assert_equal '8', Wasalx::Client.post_calls.last.dig(:payload, :reply_to_article_id)
      end
    end
  end

  def test_reply_preview_rejects_cross_ticket_private_wrong_type_and_missing_article
    [{ ticket_id: 99 }, { internal: true }, { internal: nil }, { type_id: 11 }, { sender_id: 3 },
     { sender_id: nil }].each do |values|
      Ticket::Article.reply_articles = [reply_preview_article(**values)]
      assert_raises(ActionController::BadRequest, values.inspect) { reply_preview_controller(in_reply_to: 'wasalx-article:8').reply_preview }
    end
    Ticket::Article.reply_articles = []
    ['wasalx-article:8', 'wasalx-article:0', 'wasalx-article:8x', 'x' * 513, "invalid\nsource", 8, []].each do |target|
      assert_raises(ActionController::BadRequest, target.inspect) { reply_preview_controller(in_reply_to: target).reply_preview }
    end
    assert_empty Wasalx::Client.post_calls
  end

  def test_reply_preview_requires_direct_human_state_and_valid_channel_metadata
    %w[BOT HANDOFF_PENDING RESOLVED].each do |state|
      Ticket.record.wasalx_bot_state = state
      assert_raises(Exceptions::Forbidden) { reply_preview_controller.reply_preview }
    end
    Ticket.record.wasalx_bot_state = 'HUMAN'
    reply_preview_controller.reply_preview
    assert_equal 1, Wasalx::Client.post_calls.length
    Ticket.record.wasalx_bot_state = nil
    Ticket.record.wasalx_connection_id = nil
    assert_raises(ActionController::BadRequest) { reply_preview_controller.reply_preview }
    Ticket.record = ticket
    Ticket.record.wasalx_group_id = nil
    assert_raises(ActionController::BadRequest) { reply_preview_controller.reply_preview }
    assert_equal 1, Wasalx::Client.post_calls.length
  end

  def test_reply_preview_failure_never_creates_ticket_article_or_attachment
    controller = reply_preview_controller
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('preview unavailable')]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.reply_preview }
    assert_empty Ticket.created_records
    assert_empty Ticket::Article.created_articles
    assert_empty Store.records
    assert_empty UploadCache.destroyed
  end

  def test_reply_preview_translation_upgrade_reuses_native_po_sync
    Translation.synced_locales = []
    SyncWasalxReplyPreviewTranslations.up
    assert_equal 1, UserInfo.current_user_id
    assert_equal ['ar'], Translation.synced_locales
  end

  def test_ticket_template_translation_upgrade_restores_the_acting_user
    prior = UserInfo.current_user_id
    UserInfo.current_user_id = 17
    Translation.synced_locales = []

    SyncWasalxTicketTemplateTranslations.up

    assert_equal ['ar'], Translation.synced_locales
    assert_equal 1, Translation.sync_user_id
    assert_equal 17, UserInfo.current_user_id
  ensure
    UserInfo.current_user_id = prior
  end

  def test_shared_not_found_mapping_preserves_other_failure_semantics
    controller = Api::V1::WasalxController.new
    error_class, handler = Api::V1::WasalxController.request_failure_handler
    assert_equal Wasalx::Client::RequestFailed, error_class
    failure = Wasalx::Client::PermanentRequestFailed.new('private upstream details', http_status: 404)
    controller.send(handler, failure)
    assert_equal :not_found, controller.rendered_status
    assert_equal({ error: 'Not found' }, controller.rendered)
    assert_equal false, failure.retryable?

    [Wasalx::Client::TemporaryRequestFailed.new('timeout'),
     Wasalx::Client::TemporaryRequestFailed.new('unavailable', http_status: 503),
     Wasalx::Client::PermanentRequestFailed.new('invalid', http_status: 400)].each do |error|
      assert_same error, assert_raises(error.class) { controller.send(handler, error) }
    end
  end

  def setup
    Wasalx::Client.reset_panel_test!
    ActiveSupport::SecurityUtils.comparisons = 0
    ENV['WASALX_SERVICE_JWT_SECRET'] = 'synthetic-template-recovery-secret'
    ENV['WASALX_PORTAL_URL'] = 'https://portal.wasalx.test/'
    ENV['WASALX_TENANT_ID'] = '10000000-0000-4000-8000-000000000001'
    ENV['WASALX_ZAMMAD_INSTANCE_ID'] = '11000000-0000-4000-8000-000000000001'
    Ticket.record = ticket
    Ticket.created_records = []
    Ticket.workflow_guard = nil
    WasalxTicketOperation.records = {}
    Ticket::Article.created_articles = []
    Ticket::Article.reply_articles = []
    User.records = {}
    Store.reset!
    UploadCache.reset!
    Group.record = Struct.new(:id).new(4)
    Setting.values = {
      'ui_desktop_beta_switch' => false,
      'ui_desktop_beta_switch_role_ids' => [2]
    }
  end

  def test_package_uses_modern_desktop_without_the_optional_beta_switch
    EnableWasalxModernDesktopUi.up

    assert_equal 1, UserInfo.current_user_id
    assert_equal false, Setting.values.fetch('ui_desktop_beta_switch')
    assert_equal [], Setting.values.fetch('ui_desktop_beta_switch_role_ids')
  end

  def test_portal_group_staging_denies_expired_and_wrong_destination_files_before_control_admission
    cache_id = '41000000-0000-4000-8000-000000000001'
    request_token = '42000000-0000-4000-8000-000000000002'
    controller = group_send_controller(cache_id, request_token)
    group_id = controller.params[:group_id]
    item = TestStoreItem.new(id: 27, filename: 'proof.png', file_size: 4, content: 'data', created_at: Time.now - 3601,
                             preferences: {
                               'Content-Type' => 'image/png',
                               'Wasalx-Portal-Target' => { 'kind' => 'GROUP', 'id' => group_id }
                             })
    UploadCache.seed(cache_id, [item])
    assert_raises(ActionController::BadRequest) { controller.group_workspace_send }
    assert_empty Store.records
    assert_empty Wasalx::Client.post_calls
    item.created_at = Time.now
    item.preferences['Wasalx-Portal-Target']['id'] = '47000000-0000-4000-8000-000000000007'
    assert_raises(ActionController::BadRequest) { controller.group_workspace_send }
    assert_empty Store.records
    assert_empty Wasalx::Client.post_calls
    item.preferences['Wasalx-Portal-Target']['id'] = group_id
    Wasalx::Client.post_results = [{ 'id' => '43000000-0000-4000-8000-000000000003', 'state' => 'QUEUED' }]
    controller.group_workspace_send
    assert_equal 1, Store.records.length
    assert_equal 1, Wasalx::Client.post_calls.length
    item.created_at = Time.now - 3601
    assert_raises(ActionController::BadRequest) { controller.group_workspace_send }
    assert_equal 1, Store.records.length, 'Expired browser cache deleted an admitted stable stage'
  end

  def test_group_send_rejects_another_actor_upload_before_staging
    cache_id = '41000000-0000-4000-8000-000000000001'
    request_token = '42000000-0000-4000-8000-000000000002'
    UploadCache.seed(cache_id, [TestStoreItem.new(id: 27, filename: 'foreign.png', file_size: 4, content: 'data',
                                                  created_by_id: 18, preferences: { 'Content-Type' => 'image/png' })])
    assert_raises(ActionController::BadRequest) { group_send_controller(cache_id, request_token).group_workspace_send }
    assert_empty Store.records
    assert_empty Wasalx::Client.post_calls
  end

  def test_attachment_send_reuses_staging_after_a_lost_response
    cache_id = '41000000-0000-4000-8000-000000000001'
    request_token = '42000000-0000-4000-8000-000000000002'
    UploadCache.seed(cache_id, [TestStoreItem.new(id: 27, filename: 'proof.png', file_size: 4, content: 'data',
                                                  preferences: { 'Content-Type' => 'image/png' })])
    Wasalx::Client.post_results = [
      Wasalx::Client::TemporaryRequestFailed.new('response lost'),
      { 'id' => '43000000-0000-4000-8000-000000000003', 'state' => 'QUEUED', 'duplicate' => true }
    ]

    first = group_send_controller(cache_id, request_token)
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { first.group_workspace_send }
    first_descriptor = Wasalx::Client.post_calls.last.dig(:payload, :attachments, 0)
    assert_equal 1, Store.records.length
    assert_empty UploadCache.destroyed

    replay = group_send_controller(cache_id, request_token)
    replay.group_workspace_send
    second_descriptor = Wasalx::Client.post_calls.last.dig(:payload, :attachments, 0)
    assert_equal first_descriptor, second_descriptor
    assert_equal cache_id, second_descriptor[:uploadCacheId]
    assert_equal 27, second_descriptor[:sourceStoreId]
    assert_empty UploadCache.destroyed
    assert_equal 1, Store.records.length
  end

  def test_attachment_replay_cleans_only_a_new_unreferenced_stage
    cache_id = '44000000-0000-4000-8000-000000000004'
    request_token = '45000000-0000-4000-8000-000000000005'
    UploadCache.seed(cache_id, [TestStoreItem.new(id: 28, filename: 'proof.png', file_size: 4, content: 'data',
                                                  preferences: { 'Content-Type' => 'image/png' })])
    Wasalx::Client.post_results = [
      Wasalx::Client::TemporaryRequestFailed.new('response lost'),
      { 'id' => '46000000-0000-4000-8000-000000000006', 'state' => 'SENT', 'duplicate' => true }
    ]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { group_send_controller(cache_id, request_token, 28).group_workspace_send }
    first_store_id = Store.records.fetch(0).id
    Store.remove_item(first_store_id) # The worker consumed the accepted first stage before the browser retried.

    group_send_controller(cache_id, request_token, 28).group_workspace_send
    second_store_id = Wasalx::Client.post_calls.last.dig(:payload, :attachments, 0, :store_id)
    refute_equal first_store_id, second_store_id
    assert_empty Store.records
  end

  def test_denied_group_ticket_create_cannot_mutate_the_customer
    customer = User.create!(id: 91, login: 'existing-customer', firstname: 'Customer', mobile: nil)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 17, %w[4])
    controller.current_user.denied_policies = [:create?]
    source = {
      'id' => '47000000-0000-4000-8000-000000000007', 'connection_id' => '48000000-0000-4000-8000-000000000008',
      'external_group_id' => 'test-user-1899@example.test', 'group_name' => 'Operations', 'provider' => 'WAHA',
      'external_message_id' => 'message-1', 'external_participant_id' => '12025550184@c.us',
      'zammad_customer_id' => '91', 'message_text' => 'Help'
    }

    assert_raises(Exceptions::Forbidden) do
      controller.send(:group_workspace_service).send(:find_or_create_group_ticket_article, source, '4',
                                                     'Operations — shipment')
    end
    assert_nil customer.mobile
    assert_empty Ticket::Article.created_articles
  end

  def test_manual_group_ticket_article_keeps_agent_audit_and_uses_phone_customer_as_author
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 17, %w[4])
    source = {
      'id' => '50000000-0000-4000-8000-000000000005',
      'connection_id' => '12000000-0000-4000-8000-000000000001',
      'external_message_id' => 'wamid.customer-1',
      'external_participant_id' => '12025550184@c.us',
      'participant_name' => 'Noura',
      'provider' => 'WAHA',
      'message_text' => 'Shipment update'
    }

    customer = controller.send(:group_workspace_service).send(:group_message_customer, source)
    article = controller.send(:group_workspace_service).send(:create_group_message_article, Ticket.record, source,
                                                             'manual-create', customer)

    assert_equal '+12025550184', customer.mobile
    assert_equal customer.id, article[:origin_by_id]
    assert_equal 17, article[:created_by_id]
    assert_equal 17, article[:updated_by_id]
  end

  def test_manual_link_reuses_normalized_customer_and_accepts_only_safe_meta_mobile
    existing = User.create!(id: 91, login: 'wasalx-existing', firstname: 'Customer', mobile: nil)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    source = {
      'id' => '50000000-0000-4000-8000-000000000006',
      'connection_id' => '12000000-0000-4000-8000-000000000001',
      'external_group_id' => 'test-user-1675@example.test', 'group_name' => 'Operations',
      'external_message_id' => 'wamid.customer-2',
      'external_participant_id' => '14165550184',
      'participant_name' => 'Maha',
      'provider' => 'META',
      'zammad_customer_id' => '91',
      'message_text' => 'Please help'
    }

    article = controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)

    assert_equal '+14165550184', existing.mobile
    assert_equal 18, existing.updated_by_id
    assert_equal 91, article[:origin_by_id]
    assert_equal 18, article[:created_by_id]

    existing.mobile = '+16175550184'
    source['external_participant_id'] = '19175550193'
    assert_same existing, controller.send(:group_workspace_service).send(:group_message_customer, source)
    assert_equal '+16175550184', existing.mobile

    source.delete('zammad_customer_id')
    source['id'] = '50000000-0000-4000-8000-000000000007'
    source['provider'] = 'WAHA'
    source['external_participant_id'] = '14165550145@lid'
    opaque = controller.send(:group_workspace_service).send(:group_message_customer, source)
    assert_nil opaque.mobile
  end

  def test_linking_an_unbound_ticket_binds_only_the_source_conversation
    User.create!(id: 91, login: 'wasalx-safe-bind', firstname: 'Customer', mobile: nil)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    Ticket.record.wasalx_connection_id = nil
    Ticket.record.wasalx_group_id = nil
    source = media_source('55000000-0000-4000-8000-000000000005', 'wamid.safe-bind')
    source['media_available'] = false

    controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)

    assert_equal source.fetch('connection_id'), Ticket.record.wasalx_connection_id
    assert_equal source.fetch('external_group_id'), Ticket.record.wasalx_group_id
    assert_equal source.fetch('external_message_id'), Ticket.record.wasalx_latest_external_message_id
    assert_equal 18, Ticket.record.updated_by_id
  end

  def test_linking_rejects_partial_or_different_conversation_metadata
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    source = media_source('55000000-0000-4000-8000-000000000005', 'wamid.denied-bind')

    Ticket.record.wasalx_connection_id = source.fetch('connection_id')
    Ticket.record.wasalx_group_id = nil
    assert_raises(ActionController::BadRequest) do
      controller.send(:group_workspace_service).send(:ensure_linked_ticket_destination!, Ticket.record, source)
    end

    Ticket.record.wasalx_group_id = 'test-user-0008@example.test'
    assert_raises(ActionController::BadRequest) do
      controller.send(:group_workspace_service).send(:ensure_linked_ticket_destination!, Ticket.record, source)
    end
  end

  def test_failed_remote_link_leaves_one_recoverable_bound_article
    User.create!(id: 91, login: 'wasalx-link-failure', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:link)
    Ticket.record.wasalx_connection_id = nil
    Ticket.record.wasalx_group_id = nil
    source = media_source('55000000-0000-4000-8000-000000000005', 'wamid.link-failure')
    source['media_available'] = false
    Wasalx::Client.get_results = [source]
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('link unavailable')]

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_link_ticket }
    assert_equal source.fetch('connection_id'), Ticket.record.wasalx_connection_id
    assert_equal source.fetch('external_group_id'), Ticket.record.wasalx_group_id
    assert_equal 1, Ticket::Article.created_articles.length
  end

  def test_concurrent_links_from_different_groups_cannot_cross_bind_one_ticket
    User.create!(id: 91, login: 'wasalx-first-group', firstname: 'First', mobile: nil)
    User.create!(id: 92, login: 'wasalx-second-group', firstname: 'Second', mobile: nil)
    Ticket.record.wasalx_connection_id = nil
    Ticket.record.wasalx_group_id = nil
    first = media_source('55000000-0000-4000-8000-000000000005', 'wamid.first-group')
    first['media_available'] = false
    second = media_source('55000000-0000-4000-8000-000000000006', 'wamid.second-group').merge(
      'connection_id' => '12000000-0000-4000-8000-000000000002',
      'external_group_id' => 'test-user-0819@example.test', 'group_name' => 'Second', 'zammad_customer_id' => '92',
      'media_available' => false
    )
    results = Queue.new
    [first, second].map do |source|
      Thread.new do
        controller = Api::V1::WasalxController.new
        controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
        begin
          results << controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)
        rescue ActionController::BadRequest => error
          results << error
        end
      end
    end.each(&:join)

    outcomes = 2.times.map { results.pop }
    assert_equal(1, outcomes.count { |outcome| outcome.is_a?(Hash) })
    assert_equal(1, outcomes.count { |outcome| outcome.is_a?(ActionController::BadRequest) })
    assert_equal 1, Ticket::Article.created_articles.length
    article = Ticket::Article.created_articles.first
    assert_equal Ticket.record.id, article.fetch(:ticket_id)
    assert_includes [first.fetch('connection_id'), second.fetch('connection_id')], Ticket.record.wasalx_connection_id
  end

  def test_media_only_message_creates_one_native_article_attachment_and_replays_without_downloading
    customer = User.create!(id: 91, login: 'wasalx-media', firstname: 'Customer', mobile: nil)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    source = {
      'id' => '51000000-0000-4000-8000-000000000001',
      'group_id' => '52000000-0000-4000-8000-000000000002',
      'connection_id' => '12000000-0000-4000-8000-000000000001',
      'external_group_id' => 'test-user-1675@example.test', 'group_name' => 'Operations',
      'external_message_id' => 'wamid.media-1', 'external_participant_id' => '14165550184',
      'participant_name' => 'Maha', 'provider' => 'META', 'zammad_customer_id' => '91',
      'message_text' => nil, 'media_kind' => 'image', 'media_filename' => 'proof.png', 'media_available' => true
    }
    Wasalx::Client.get_results = [{
      'url' => 'https://media.example/signed', 'filename' => 'proof.png',
      'mime_type' => 'image/png', 'byte_size' => 4, 'sha256' => Digest::SHA256.hexdigest('data')
    }]
    Wasalx::Client.download_result = { data: 'data', content_type: 'image/png' }

    article = controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)
    replay = controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)

    assert_same article, replay
    assert_equal 'Image: proof.png', article[:body]
    assert_equal customer.id, article[:origin_by_id]
    attachment = Store.records.fetch(0)
    assert_equal 'Ticket::Article', attachment.object
    assert_equal article.id, attachment.o_id
    assert_equal 'proof.png', attachment.filename
    assert_equal({ 'Mime-Type' => 'image/png' }, attachment.preferences)
    assert_equal [{ url: 'https://media.example/signed', maximum_bytes: 4, expected_content_type: 'image/png',
                    expected_sha256: Digest::SHA256.hexdigest('data') }],
                 Wasalx::Client.download_calls
    assert_equal(1, Wasalx::Client.get_calls.count { |call| call[:path].end_with?('/media') })
  end

  def test_group_cancel_fences_a_delayed_create_without_a_fake_ticket
    controller = group_ticket_controller(:create)
    workspace = controller.send(:group_workspace_service)
    source = media_source(controller.params[:message_id], 'wamid.cancel').merge('media_available' => false)
    Wasalx::Client.get_results = [source, source, source]
    input = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id], message_id: controller.params[:message_id],
              request_token: controller.params[:request_token] }
    assert_equal 'UNKNOWN', workspace.group_receipt(**input)['state']
    result = workspace.group_receipt(**input, action: 'CANCEL_IF_UNADMITTED')
    assert_equal 'NOT_APPLIED', result['state']
    assert_equal true, result['terminal']
    assert_nil WasalxTicketOperation.records[input[:request_token]].ticket_id
    assert_raises(Wasalx::GroupWorkspace::Conflict) { controller.group_workspace_create_ticket }
    assert_empty Ticket.created_records
    assert_empty Ticket::Article.created_articles
    assert_empty Wasalx::Client.post_calls
  end

  def test_missing_link_target_rejection_is_durable_and_cancellable_after_reload
    controller = group_ticket_controller(:link)
    controller.params[:ticket_number] = '99999999'
    source = media_source(controller.params[:message_id], 'wamid.missing-target').merge('media_available' => false)
    Wasalx::Client.get_results = [source, source]
    error = assert_raises(Wasalx::GroupWorkspace::RejectedMissing) { controller.group_workspace_link_ticket }
    assert_equal 404, error.status
    assert_equal 'GROUP_OPERATION_REJECTED', error.result['code']
    assert_equal 'NONE', error.result['effect']
    workspace = controller.send(:group_workspace_service)
    result = workspace.group_receipt(kind: 'GROUP_LINK', group_id: controller.params[:group_id],
                                     message_id: controller.params[:message_id],
                                     request_token: controller.params[:request_token],
                                     ticket_number: controller.params[:ticket_number], action: 'CANCEL_IF_UNADMITTED')
    assert_equal 'NOT_APPLIED', result['state']
    assert_empty Ticket::Article.created_articles
    assert_empty Wasalx::Client.post_calls
  end

  def test_group_native_receipt_rejects_changed_intent_and_scope_collisions
    User.create!(id: 91, login: 'group-receipt-binding', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.binding').merge('media_available' => false)
    Wasalx::Client.get_results = [source, source, source, source]
    Wasalx::Client.post_results = [{ 'linked' => true }]
    controller.group_workspace_create_ticket
    controller.params[:title] = 'Changed intent'
    assert_raises(Wasalx::GroupWorkspace::Conflict) { controller.group_workspace_create_ticket }
    receipt = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id],
                message_id: controller.params[:message_id],
                request_token: controller.params[:request_token] }
    controller.current_user = FakeUser.new(%w[ticket.agent], 17, %w[4])
    assert_raises(Wasalx::GroupWorkspace::Conflict) { controller.send(:group_workspace_service).group_receipt(**receipt) }
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    assert_raises(Wasalx::GroupWorkspace::Conflict) do
      link_receipt = receipt.merge(kind: 'GROUP_LINK', ticket_number: Ticket.created_records.first.number)
      controller.send(:group_workspace_service).group_receipt(**link_receipt)
    end
    assert_equal 1, Ticket.created_records.length
    assert_equal 1, Ticket::Article.created_articles.length
    assert_equal 1, Wasalx::Client.post_calls.length
  end

  def test_partial_group_receipt_never_cancels_and_repairs_only_remote_link
    User.create!(id: 91, login: 'group-partial', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.partial').merge('media_available' => false)
    Wasalx::Client.get_results = [source]
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('lost')]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_create_ticket }
    input = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id], message_id: controller.params[:message_id],
              request_token: controller.params[:request_token] }
    workspace = controller.send(:group_workspace_service)
    Wasalx::Client.get_results = [source, source]
    assert_equal 'PARTIAL', workspace.group_receipt(**input)['state']
    assert_equal 'PARTIAL', workspace.group_receipt(**input, action: 'CANCEL_IF_UNADMITTED')['state']
    article = Ticket::Article.created_articles.first
    complete = source.merge('links' => [{ 'ticket_id' => article.ticket_id.to_s, 'article_id' => article.id.to_s }])
    Wasalx::Client.get_results = [source, complete]
    Wasalx::Client.post_results = [{ 'linked' => true, 'duplicate' => true }]
    result = workspace.repair_ticket_link(**input)
    assert_equal 'COMPLETE', result['state']
    assert_equal article.ticket.number, result['ticket_number']
    assert_equal 1, Ticket.created_records.length
    assert_equal 1, Ticket::Article.created_articles.length
    assert_equal 2, Wasalx::Client.post_calls.length
  end

  def test_legacy_native_article_cannot_be_misreported_as_absent_by_cancellation
    User.create!(id: 91, login: 'legacy-article', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.legacy').merge('media_available' => false)
    workspace = controller.send(:group_workspace_service)
    article = workspace.send(:find_or_create_group_ticket_article, source, '4', controller.params[:title])
    Wasalx::Client.get_results = [source]
    result = workspace.group_receipt(kind: 'GROUP_CREATE', group_id: controller.params[:group_id],
                                     message_id: controller.params[:message_id],
                                     request_token: controller.params[:request_token], action: 'CANCEL_IF_UNADMITTED')
    assert_equal 'PARTIAL', result['state']
    assert_equal article.id.to_s, result['article_id']
    assert_empty WasalxTicketOperation.records
    assert_empty Wasalx::Client.post_calls
  end

  def test_group_cancellation_recovers_after_source_retention_but_still_requires_group_access
    controller = group_ticket_controller(:create)
    workspace = controller.send(:group_workspace_service)
    missing = Wasalx::Client::PermanentRequestFailed.new('Retained source absent', http_status: 404)
    Wasalx::Client.get_results = [missing]
    failure = assert_raises(Wasalx::GroupWorkspace::RejectedMissing) { controller.group_workspace_create_ticket }
    assert_equal 'NOT_APPLIED', failure.result['state']
    input = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id], message_id: controller.params[:message_id],
              request_token: controller.params[:request_token] }
    Wasalx::Client.get_results = [RuntimeError.new('Must not fetch retired content')]
    assert_equal 'NOT_APPLIED', workspace.group_receipt(**input)['state']
    assert_equal 'NOT_APPLIED', workspace.repair_ticket_link(**input)['state']
    assert_raises(Wasalx::GroupWorkspace::Conflict) { controller.group_workspace_create_ticket }
    Wasalx::Client.test_error = Exceptions::Forbidden.new('Group grant revoked')
    assert_raises(Exceptions::Forbidden) { workspace.group_receipt(**input) }
    assert_empty Ticket.created_records
    assert_empty Wasalx::Client.post_calls
  end

  def test_group_committed_receipt_with_retired_source_never_cancels_or_posts_repair
    User.create!(id: 91, login: 'retired-source', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.retired').merge('media_available' => false)
    Wasalx::Client.get_results = [source]
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('lost')]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_create_ticket }
    input = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id], message_id: controller.params[:message_id],
              request_token: controller.params[:request_token] }
    workspace = controller.send(:group_workspace_service)
    missing = Wasalx::Client::PermanentRequestFailed.new('Source purged', http_status: 404)
    Wasalx::Client.get_results = [missing, missing]
    assert_equal 'PARTIAL', workspace.group_receipt(**input, action: 'CANCEL_IF_UNADMITTED')['state']
    assert_equal 'PARTIAL', workspace.repair_ticket_link(**input)['state']
    assert_equal 'GROUP_CREATE', WasalxTicketOperation.records[input[:request_token]].kind
    assert_equal 1, Wasalx::Client.post_calls.length
  end

  def test_group_changed_article_mapping_conflicts_before_lookup_or_repair_post
    User.create!(id: 91, login: 'changed-article', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.changed').merge('media_available' => false)
    Wasalx::Client.get_results = [source]
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('lost')]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_create_ticket }
    article = Ticket::Article.created_articles.first
    changed = source.merge('links' => [{ 'ticket_id' => article.ticket_id.to_s,
                                         'article_id' => (article.id.to_i + 1).to_s }])
    Wasalx::Client.get_results = [changed, changed]
    input = { kind: 'GROUP_CREATE', group_id: controller.params[:group_id], message_id: controller.params[:message_id],
              request_token: controller.params[:request_token] }
    workspace = controller.send(:group_workspace_service)
    assert_raises(Wasalx::GroupWorkspace::Conflict) { workspace.group_receipt(**input) }
    assert_raises(Wasalx::GroupWorkspace::Conflict) { workspace.repair_ticket_link(**input) }
    assert_equal 1, Wasalx::Client.post_calls.length
    assert_equal 1, Ticket::Article.created_articles.length
  end

  def test_explicit_legacy_link_binds_unbound_ticket_only_with_native_update_authority
    controller = group_ticket_controller(:link)
    controller.send(:group_workspace_service)
    source = media_source(controller.params[:message_id], 'wamid.explicit').merge('media_available' => false)
    article = Ticket::Article.create!(ticket_id: Ticket.record.id, wasalx_operation_key: nil, created_by_id: 18)
    source['links'] = [{ 'ticket_id' => article.ticket_id.to_s, 'article_id' => article.id.to_s }]
    Ticket.record.wasalx_connection_id = nil
    Ticket.record.wasalx_group_id = nil
    controller.current_user.denied_policies = [:agent_update_access?]
    Wasalx::Client.get_results = [source]
    assert_raises(Exceptions::Forbidden) { controller.group_workspace_link_ticket }
    assert_nil Ticket.record.wasalx_connection_id
    assert_empty WasalxTicketOperation.records
    assert_empty Wasalx::Client.post_calls
    controller.current_user.denied_policies = []
    Wasalx::Client.get_results = [source]
    controller.group_workspace_link_ticket
    assert_equal source['connection_id'], Ticket.record.wasalx_connection_id
    assert_equal source['external_group_id'], Ticket.record.wasalx_group_id
    assert_equal 1, Ticket::Article.created_articles.length
    assert_empty Wasalx::Client.post_calls
  end

  def test_read_only_create_replay_cannot_complete_a_missing_remote_link
    User.create!(id: 91, login: 'read-only-repair', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.read-only').merge('media_available' => false)
    Wasalx::Client.get_results = [source, source]
    Wasalx::Client.post_results = [Wasalx::Client::TemporaryRequestFailed.new('link lost')]
    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_create_ticket }
    controller.current_user = FakeUser.new(%w[ticket.agent], 17, %w[4])
    controller.params[:request_token] = '59000000-0000-4000-8000-000000000009'
    controller.current_user.denied_policies = [:create?, :agent_update_access?]
    assert_raises(Exceptions::Forbidden) { controller.group_workspace_create_ticket }
    assert_equal 1, Wasalx::Client.post_calls.length
    assert_equal 1, Ticket.created_records.length
    article = Ticket::Article.created_articles.first
    Wasalx::Client.get_results = [source.merge('links' => [{ 'ticket_id' => article.ticket_id.to_s,
                                                             'article_id' => article.id.to_s }])]
    controller.group_workspace_create_ticket
    assert_equal :ok, controller.rendered_status
    assert_equal article.ticket_id.to_s, controller.rendered[:ticket_id]
    assert_equal 1, Wasalx::Client.post_calls.length
  end

  def test_shared_group_writes_supply_native_workflow_screen_and_human_actor
    User.create!(id: 91, login: 'workflow-screen', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source(controller.params[:message_id], 'wamid.workflow').merge('media_available' => false)
    Wasalx::Client.get_results = [source]
    observed = []
    Ticket.workflow_guard = lambda do |record, operation, _changes|
      observed << [operation, record.screen, UserInfo.current_user_id]
      raise ActionController::BadRequest, 'Restricted native workflow' if record.screen == 'create_middle'
    end
    assert_raises(ActionController::BadRequest) { controller.group_workspace_create_ticket }
    assert_equal [[:create, 'create_middle', 18]], observed
    assert_empty Ticket.created_records
    assert_empty Ticket::Article.created_articles
    assert_empty Wasalx::Client.post_calls

    Ticket.workflow_guard = lambda do |record, operation, _changes|
      observed << [operation, record.screen, UserInfo.current_user_id]
      raise ActionController::BadRequest, 'Restricted native workflow' if record.screen == 'edit'
    end
    controller = group_ticket_controller(:link)
    source = media_source(controller.params[:message_id], 'wamid.workflow-link').merge('media_available' => false)
    Wasalx::Client.get_results = [source]
    assert_raises(ActionController::BadRequest) { controller.group_workspace_link_ticket }
    assert_equal [:update, 'edit', 18], observed.last
    assert_empty Ticket::Article.created_articles
    assert_empty Wasalx::Client.post_calls
  end

  def test_media_only_ticket_creation_replays_a_lost_link_without_a_second_ticket_or_download
    User.create!(id: 91, login: 'wasalx-media-create', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:create)
    source = media_source('54000000-0000-4000-8000-000000000004', 'wamid.media-create')
    Wasalx::Client.get_results = [source, media_metadata, source]
    Wasalx::Client.download_result = { data: 'data', content_type: 'image/png' }
    Wasalx::Client.post_results = [
      Wasalx::Client::TemporaryRequestFailed.new('link response lost'),
      { 'linked' => true, 'duplicate' => true }
    ]

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_create_ticket }
    controller.group_workspace_create_ticket

    assert_equal 1, Ticket.created_records.length
    assert_equal 1, Ticket::Article.created_articles.length
    assert_equal 1, Store.records.length
    assert_equal 1, Wasalx::Client.download_calls.length
    assert_equal(1, Wasalx::Client.get_calls.count { |call| call[:path].end_with?('/media') })
    link_calls = Wasalx::Client.post_calls.select { |call| call[:path].end_with?('/tickets') }
    assert_equal 2, link_calls.length
    assert_equal 1, link_calls.map { |call| call.dig(:payload, :idempotency_key) }.uniq.length
    assert_equal :ok, controller.rendered_status
    assert_equal Ticket.created_records.first.id.to_s, controller.rendered.fetch(:ticket_id)
  end

  def test_media_only_ticket_link_replays_a_lost_response_without_a_second_article_or_download
    User.create!(id: 91, login: 'wasalx-media-link', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:link)
    source = media_source('55000000-0000-4000-8000-000000000005', 'wamid.media-link')
    Wasalx::Client.get_results = [source, media_metadata, source]
    Wasalx::Client.download_result = { data: 'data', content_type: 'image/png' }
    Wasalx::Client.post_results = [
      Wasalx::Client::TemporaryRequestFailed.new('link response lost'),
      { 'linked' => true, 'duplicate' => true }
    ]

    assert_raises(Wasalx::Client::TemporaryRequestFailed) { controller.group_workspace_link_ticket }
    controller.group_workspace_link_ticket

    assert_equal 1, Ticket::Article.created_articles.length
    assert_equal 1, Store.records.length
    assert_equal 1, Wasalx::Client.download_calls.length
    assert_equal(1, Wasalx::Client.get_calls.count { |call| call[:path].end_with?('/media') })
    link_calls = Wasalx::Client.post_calls.select { |call| call[:path].end_with?('/tickets') }
    assert_equal 2, link_calls.length
    assert_equal 1, link_calls.map { |call| call.dig(:payload, :idempotency_key) }.uniq.length
    assert_nil controller.rendered_status
    assert_equal Ticket.record.id.to_s, controller.rendered.fetch(:ticket_id)
  end

  def test_inaccessible_media_fails_closed_before_creating_a_ticket_article
    User.create!(id: 91, login: 'wasalx-media-denied', firstname: 'Customer', mobile: nil)
    controller = group_ticket_controller(:link)
    source = media_source('56000000-0000-4000-8000-000000000006', 'wamid.media-denied')
    controller.params[:message_id] = source.fetch('id')
    Wasalx::Client.get_results = [source, Wasalx::Client::PermanentRequestFailed.new('media unavailable')]

    assert_raises(Wasalx::Client::PermanentRequestFailed) { controller.group_workspace_link_ticket }
    assert_empty Ticket::Article.created_articles
    assert_empty Store.records
    assert_empty Wasalx::Client.download_calls
    assert_empty Wasalx::Client.post_calls
  end

  def test_unavailable_media_keeps_a_safe_article_label_without_downloading
    customer = User.create!(id: 92, login: 'wasalx-expired-media', firstname: 'Customer', mobile: nil)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    source = {
      'id' => '53000000-0000-4000-8000-000000000003',
      'connection_id' => '12000000-0000-4000-8000-000000000001',
      'external_group_id' => 'test-user-1675@example.test', 'group_name' => 'Operations',
      'external_message_id' => 'wamid.media-expired', 'external_participant_id' => '19175550193',
      'participant_name' => 'Noura', 'provider' => 'META', 'zammad_customer_id' => '92',
      'message_text' => nil, 'media_kind' => 'document', 'media_filename' => 'manifest.pdf', 'media_available' => false
    }

    article = controller.send(:group_workspace_service).send(:find_or_create_link_article, source, Ticket.record)

    assert_equal 'Document: manifest.pdf', article[:body]
    assert_equal customer.id, article[:origin_by_id]
    assert_empty Store.records
    assert_empty Wasalx::Client.download_calls
  end

  def test_deleted_group_message_cannot_start_a_new_ticket_action
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    error = assert_raises(ActionController::BadRequest) do
      controller.send(:group_workspace_service).send(:ensure_group_message_actionable!,
                                                     { 'latest_mutation' => 'REVOKED' })
    end
    assert_equal 'Deleted messages cannot be added to a ticket.', error.message
  end

  def ticket
    FakeTicket.new(
      id: 42,
      group_id: 4,
      title: 'Operations — proof',
      number: '10382',
      wasalx_reference: 'ABC1234567',
      wasalx_group_id: 'test-user-1675@example.test',
      wasalx_group_name: 'Local Operations',
      wasalx_connection_id: '12000000-0000-4000-8000-000000000001',
      wasalx_provider: 'WAHA',
      wasalx_correlation_status: 'OPEN',
      wasalx_rule_version: 'rules-v7',
      wasalx_delivery_status: 'SENT'
    )
  end

  def group_send_controller(cache_id, request_token, store_id = 27)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 17, %w[4])
    controller.params = {
      group_id: '49000000-0000-4000-8000-000000000009', request_token: request_token,
      message: 'Shipment proof', upload_cache_id: cache_id, upload_store_ids: [store_id]
    }
    controller
  end

  def group_ticket_controller(action)
    controller = Api::V1::WasalxController.new
    controller.current_user = FakeUser.new(%w[ticket.agent], 18, %w[4])
    controller.params = {
      group_id: '52000000-0000-4000-8000-000000000002',
      message_id: action == :create ? '54000000-0000-4000-8000-000000000004' : '55000000-0000-4000-8000-000000000005',
      request_token: (action == :create ? '57000000-0000-4000-8000-000000000007' :
                                          '58000000-0000-4000-8000-000000000008'),
      target_group_id: '4', title: 'Operations — proof', ticket_number: Ticket.record.number
    }
    controller
  end

  def media_source(id, external_message_id)
    {
      'id' => id, 'group_id' => '52000000-0000-4000-8000-000000000002',
      'connection_id' => '12000000-0000-4000-8000-000000000001',
      'external_group_id' => 'test-user-1675@example.test', 'group_name' => 'Operations',
      'external_message_id' => external_message_id, 'external_participant_id' => '14165550184',
      'participant_name' => 'Maha', 'provider' => 'META', 'zammad_customer_id' => '91',
      'message_text' => nil, 'media_kind' => 'image', 'media_filename' => 'proof.png',
      'media_available' => true, 'from_me' => false, 'ticket_creatable' => true, 'links' => []
    }
  end

  def media_metadata
    { 'url' => 'https://media.example/signed', 'filename' => 'proof.png', 'mime_type' => 'image/png', 'byte_size' => 4,
      'sha256' => Digest::SHA256.hexdigest('data') }
  end

  def test_panel_uses_truthful_remote_state_and_minimal_local_metadata
    Ticket.record.wasalx_correlation_status = 'RESOLVED'
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent.wasalx_retry], 17, %w[4])
    ).execute

    assert_equal 'WORKING', panel.dig(:connection, :state)
    assert_equal 'DELIVERED', panel.dig(:delivery, :state)
    assert_equal '30000000-0000-4000-8000-000000000003', panel.dig(:delivery, :id)
    assert_equal '9', panel.dig(:delivery, :article_id)
    assert_equal false, panel.dig(:delivery, :retry_allowed)
    assert_equal 'OPEN', panel.dig(:ticket, :correlation_status)
    assert_equal 'Riyadh Operations', panel.dig(:group, :name)
    assert_equal '40000000-0000-4000-8000-000000000004', panel.dig(:message_context, :group_id)
    assert_equal '50000000-0000-4000-8000-000000000005', panel.dig(:message_context, :message_id)
    assert_equal [panel[:message_context]], panel[:message_contexts]
    assert_equal({ sender_name: 'Customer One', sender_phone: '+12025550184', from_me: false }, panel[:trigger_sender])
    assert_equal false, panel[:message_contexts_truncated]
    assert_equal true, panel.dig(:connection, :available)
    assert_equal true, panel[:can_retry]
    assert_nil panel[:service_window_expires_at]
    assert_equal 'https://portal.wasalx.test/?view=cases&ticket=10382', panel[:portal_url]
    assert_equal(
      [
        { path: '/internal/v1/zammad/tickets/42/context', scope: 'zammad:context' },
        { path: '/internal/v1/zammad/group-workspace/tickets/42/message-context', scope: 'zammad:groups' }
      ],
      Wasalx::Client.get_calls
    )
    serialized = panel.to_s
    refute_match(/message_body|payload|secret/i, serialized)
  end

  def test_email_only_panel_projects_applied_routing_without_a_control_plane_lookup
    Ticket.record.wasalx_connection_id = nil
    Ticket.record.wasalx_group_id = nil
    article = Struct.new(:id, :preferences, :updated_at)
    Ticket.record.articles = [article.new(19, {
                                            'wasalx_email_routing_payload' => {},
                                            'wasalx_email_routing_state' => 'APPLIED',
                                            'wasalx_email_routing_ack_state' => 'SUCCEEDED'
                                          }, Time.utc(2026, 9, 4, 10, 0, 0))]

    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent.wasalx_retry], 17, %w[4])
    ).execute

    assert_equal 'email-routing', panel.dig(:group, :id)
    assert_equal 'email-routing', panel.dig(:connection, :id)
    assert_equal 'APPLIED', panel.dig(:email_routing, :routing_state)
    assert_equal 'SUCCEEDED', panel.dig(:email_routing, :acknowledgement_state)
    assert_equal false, panel.dig(:email_routing, :retry_allowed)
    assert_empty panel[:message_contexts]
    assert_empty Wasalx::Client.get_calls
  end

  def test_panel_exposes_every_bounded_linked_message_context
    Wasalx::Client.get_results = [Wasalx::Client.test_response, {
      'items' => [
        { 'group_id' => '40000000-0000-4000-8000-000000000004', 'message_id' => '50000000-0000-4000-8000-000000000005',
          'sender_name' => 'Customer One', 'sender_phone' => '+12025550184', 'from_me' => false },
        { 'group_id' => '40000000-0000-4000-8000-000000000004', 'message_id' => '50000000-0000-4000-8000-000000000006',
          'sender_name' => 'Agent One', 'sender_phone' => '+12025550132', 'from_me' => true }
      ],
      'truncated' => true
    }]

    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent], 17, %w[4])
    ).execute

    assert_equal 2, panel[:message_contexts].length
    assert_equal panel[:message_contexts].first, panel[:message_context]
    assert_equal true, panel[:message_contexts_truncated]
  end

  def test_panel_hides_administrative_link_without_retry_permission
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new([])
    ).execute

    assert_nil panel[:portal_url]
    assert_equal false, panel[:can_retry]
  end

  def test_group_actor_does_not_elevate_inherited_agent_permissions
    [false, true].each do |admin|
      user = FakeUser.new(admin ? %w[ticket.agent admin] : %w[ticket.agent], 17, [4])
      assert user.permissions?('ticket.agent.wasalx_groups_admin')
      controller = Api::V1::WasalxController.new
      controller.current_user = user
      panel = Service::Ticket::WasalxPanel.new(ticket: Ticket.record, current_user: user)
      [controller, panel].each do |boundary|
        assert_equal({ user_id: 17, group_ids: [4], group_admin: admin }, boundary.send(:group_actor))
      end
    end
  end

  def test_group_workspace_ticket_does_not_require_an_automation_reference
    Ticket.record.wasalx_reference = nil
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute

    assert_nil panel.dig(:ticket, :reference)
    assert_equal 'WORKING', panel.dig(:connection, :state)
  end

  def test_control_plane_failure_is_explicit_and_preserves_last_local_delivery_state
    Wasalx::Client.test_error = Wasalx::Client::TemporaryRequestFailed.new('HTTP 503')
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute

    assert_equal false, panel.dig(:connection, :available)
    assert_equal 'UNAVAILABLE', panel.dig(:connection, :state)
    assert_equal 'SENT', panel.dig(:delivery, :state)
    assert_equal 'Local Operations', panel.dig(:group, :name)
  end

  def test_local_sender_fallback_ignores_a_newer_agent_article
    article = Struct.new(:preferences, :origin_by_id)
    Ticket.record.articles = [
      article.new(
        { 'wasalx_origin' => 'provider', 'wasalx_sender_name' => 'Customer One',
          'wasalx_sender_phone' => '+12025550184' }, 91
      ),
      article.new(
        { 'wasalx_origin' => 'provider', 'wasalx_sender_name' => 'Agent One',
          'wasalx_sender_phone' => '+12025550132' }, nil
      )
    ]
    Wasalx::Client.test_error = Wasalx::Client::TemporaryRequestFailed.new('HTTP 503')

    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute

    assert_equal({ sender_name: 'Customer One', sender_phone: '+12025550184', from_me: false }, panel[:trigger_sender])
  end

  def test_panel_exposes_only_the_exact_retryable_delivery_identity
    Wasalx::Client.test_response['delivery_state'] = 'OUTCOME_UNKNOWN'
    Wasalx::Client.test_response['delivery_retry_allowed'] = true
    Wasalx::Client.test_response['delivery_retry_requires_confirmation'] = true
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent.wasalx_retry])
    ).execute

    assert_equal '30000000-0000-4000-8000-000000000003', panel.dig(:delivery, :id)
    assert_equal '9', panel.dig(:delivery, :article_id)
    assert_equal true, panel.dig(:delivery, :retry_allowed)
    assert_equal true, panel.dig(:delivery, :retry_requires_confirmation)
  end

  def test_panel_normalizes_the_direct_service_window_expiry_to_utc
    Wasalx::Client.test_response['service_window_expires_at'] = '2026-08-10T23:00:00+03:00'
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute
    assert_equal '2026-08-10T20:00:00.000000Z', panel[:service_window_expires_at]

    Wasalx::Client.test_error = Wasalx::Client::TemporaryRequestFailed.new('HTTP 503')
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute
    assert_nil panel[:service_window_expires_at]
  end

  def test_mismatched_remote_connection_fails_closed
    Wasalx::Client.test_response['connection_id'] = 'another-connection'
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[ticket.agent])
    ).execute

    assert_equal false, panel.dig(:connection, :available)
    assert_equal 'UNAVAILABLE', panel.dig(:connection, :state)
  end

  def test_missing_ticket_metadata_and_unsafe_portal_urls_are_rejected
    Ticket.record.wasalx_group_id = nil
    assert_raises(ActiveRecord::RecordNotFound) do
      Service::Ticket::WasalxPanel.new(
        ticket: Ticket.record,
        current_user: FakeUser.new(%w[ticket.agent])
      ).execute
    end

    Ticket.record = ticket
    ENV['WASALX_PORTAL_URL'] = 'http://portal.wasalx.test/@unsafe'
    panel = Service::Ticket::WasalxPanel.new(
      ticket: Ticket.record,
      current_user: FakeUser.new(%w[admin])
    ).execute
    assert_nil panel[:portal_url]
  end

  def test_controller_requires_agent_read_access_before_rendering_panel
    assert_equal [:authentication_check], Api::V1::WasalxController.prepended_before_actions
    controller = Api::V1::WasalxController.new
    controller.params = { ticket_id: '42' }
    controller.current_user = FakeUser.new(%w[ticket.agent])
    controller.panel

    assert_equal [Ticket.record, :agent_read_access?], controller.authorization
    assert_equal 42, controller.rendered.dig(:ticket, :id)
  end

  def test_retry_controller_scopes_delivery_and_preserves_browser_idempotency
    controller = Api::V1::WasalxController.new
    controller.params = {
      ticket_id: '42', article_id: '9',
      delivery_id: '30000000-0000-4000-8000-000000000003',
      request_token: '40000000-0000-4000-8000-000000000004',
      confirm_outcome_unknown: true
    }
    controller.current_user = FakeUser.new(%w[ticket.agent.wasalx_retry], 77, [4])
    controller.retry_delivery

    assert_equal [Ticket.record, :agent_update_access?], controller.authorization
    assert_equal :accepted, controller.rendered_status
    assert_equal 'QUEUED', controller.rendered.fetch('state')
    call = Wasalx::Client.post_calls.fetch(0)
    assert_equal '/internal/v1/zammad/retry', call.fetch(:path)
    assert_equal 'zammad:retry', call.fetch(:scope)
    assert_equal({ user_id: 77, group_ids: [4], group_admin: false }, call.fetch(:actor))
    assert_equal '11000000-0000-4000-8000-000000000001', call.dig(:payload, :instance_id)
    assert_equal '30000000-0000-4000-8000-000000000003', call.dig(:payload, :delivery_id)
    assert_equal 'retry:42:9:30000000-0000-4000-8000-000000000003:40000000-0000-4000-8000-000000000004',
                 call.dig(:payload, :idempotency_key)
    assert_equal true, call.dig(:payload, :confirm_outcome_unknown)
  end
end

class ActiveRecord::Migration
  class << self
    attr_accessor :calls, :constraint_present, :fail_add, :constraint_sql

    def check_constraint_exists?(_table, name:)
      calls << [:check, name]
      constraint_present
    end

    def add_check_constraint(_table, sql, name:)
      calls << [:add, name]
      raise 'Synthetic DDL failure' if fail_add

      self.constraint_sql = sql
      self.constraint_present = true
    end

    def change_column_null(table, column, nullable)
      calls << [:nullable, table, column, nullable]
    end
  end
end
load File.join(ROOT, 'zammad-package/db/addon/wasalx/202610180002_extend_wasalx_ticket_operation_cancellation.rb')

class NativeGroupCancellationMigrationContract < Minitest::Test
  def setup
    ActiveRecord::Migration.calls = []
    ActiveRecord::Migration.constraint_present = false
    ActiveRecord::Migration.fail_add = false
  end

  def test_constraint_is_installed_before_nullable_column_and_only_cancellation_kinds_allow_null
    ExtendWasalxTicketOperationCancellation.up
    assert_equal [:check, :add, :nullable], ActiveRecord::Migration.calls.map(&:first)
    assert_equal ['CANCELLED_GROUP_CREATE', 'CANCELLED_GROUP_LINK', 'CANCELLED_CREATE_TICKET'],
                 ActiveRecord::Migration.constraint_sql.scan(/'([^']+)'/).flatten
    assert_equal [:nullable, :wasalx_ticket_operations, :ticket_id, true], ActiveRecord::Migration.calls.last
  end

  def test_rerun_preserves_constraint_and_retries_column_transition
    ActiveRecord::Migration.constraint_present = true
    ExtendWasalxTicketOperationCancellation.up
    assert_equal [:check, :nullable], ActiveRecord::Migration.calls.map(&:first)
  end

  def test_failed_constraint_never_relaxes_nullability
    ActiveRecord::Migration.fail_add = true
    assert_raises(RuntimeError) { ExtendWasalxTicketOperationCancellation.up }
    refute(ActiveRecord::Migration.calls.any? { |call| call.first == :nullable })
  end
end
