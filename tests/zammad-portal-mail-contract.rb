# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'minitest/autorun'
require 'ostruct'
require 'fileutils'
require 'pathname'
require 'tmpdir'
require_relative '../zammad-package/lib/wasalx/portal_mail'

class PortalMailContractTest < Minitest::Test
  def setup
    @previous = ENV.to_h.slice('WASALX_PORTAL_URL', 'ZAMMAD_FQDN', 'WASALX_TENANT_ID')
    ENV['WASALX_PORTAL_URL'] = 'https://app.wasalx.example/'
    ENV['ZAMMAD_FQDN'] = 'case.wasalx.example'
    ENV['WASALX_TENANT_ID'] = '10000000-0000-4000-8000-000000000001'
  end

  def teardown
    %w[WASALX_PORTAL_URL ZAMMAD_FQDN WASALX_TENANT_ID].each { |key| @previous.key?(key) ? ENV[key] = @previous[key] : ENV.delete(key) }
  end

  def test_only_https_or_exact_loopback_origins_are_accepted
    assert_equal 'https://app.wasalx.example', Wasalx::PortalMail.origin!
    ENV['WASALX_PORTAL_URL'] = 'http://127.0.0.1:3000'
    assert_equal 'http://127.0.0.1:3000', Wasalx::PortalMail.origin!
    ['', 'http://app.example', 'https://user@app.example', 'https://app.example/app',
     'https://app.example/?x=1', 'https://app.example/#fragment', '//app.example'].each do |url|
      ENV['WASALX_PORTAL_URL'] = url
      assert_raises(Wasalx::PortalMail::ReviewRequired) { Wasalx::PortalMail.origin! }
    end
  end

  def test_staff_link_binds_workspace_and_safe_return_route
    link = CGI.unescapeHTML(Wasalx::PortalMail.ticket_link_source!)
    uri = URI.parse(link.gsub('#{ticket.number}', '1042'))
    assert_equal 'https', uri.scheme
    assert_equal 'app.wasalx.example', uri.host
    assert_equal '/auth/login', uri.path
    params = URI.decode_www_form(uri.query).to_h
    assert_equal ENV['WASALX_TENANT_ID'], params['tenant_id']
    assert_equal '/app?view=inbox&ticket=1042', params['return_to']
    ENV['WASALX_TENANT_ID'] = 'tenant&return_to=https://foreign.example'
    assert_raises(Wasalx::PortalMail::ReviewRequired) { Wasalx::PortalMail.ticket_link_source! }
  end

  def test_custom_body_and_unrelated_perform_fields_are_preserved
    perform = { 'notification.email' => { 'body' => 'custom customer text', 'recipient' => 'custom',
      'subject' => 'custom subject', 'internal' => true }, 'other.action' => { 'value' => 7 } }
    original = Marshal.load(Marshal.dump(perform))
    assert_nil Wasalx::PortalMail.seed_perform('auto reply (on new tickets)', perform)
    assert_equal original, perform
    assert_nil Wasalx::PortalMail.seed_perform('unknown trigger', perform)
  end

  def test_all_pinned_seed_bodies_change_only_body_and_are_idempotent
    fixtures = %w[new-ticket-body followup-body owner-change-body]
    Wasalx::PortalMail::SEEDS.each_key.with_index do |name, index|
      body = File.binread(File.join(__dir__, 'fixtures/portal-mail-native', fixtures[index] + '.txt'))
      perform = { 'notification.email' => { 'body' => body, 'recipient' => 'custom recipient',
        'subject' => 'custom subject', 'internal' => false }, 'other.action' => { 'value' => 7 } }
      result = Wasalx::PortalMail.seed_perform(name, perform)
      refute_nil result
      assert_equal perform['notification.email'].except('body'), result['notification.email'].except('body')
      assert_equal perform['other.action'], result['other.action']
      assert_equal body, perform['notification.email']['body']
      refute Wasalx::PortalMail.legacy_source?(result['notification.email']['body'])
      assert_includes result['notification.email']['body'], 'reply to this email'
      assert_nil Wasalx::PortalMail.seed_perform(name, result)
    end
  end

  def template_factory(body, custom: false)
    base = Class.new do
      define_method(:template_read) { |_data| { subject: 'unchanged subject', body: body } }
      define_method(:template_path) { |_data| custom ? '/en.html.erb.custom' : '/en.html.erb' }
      private :template_path
    end
    Class.new(base) { prepend Wasalx::PortalMail::Templates }.new
  end

  def test_ticket_links_use_number_and_preserve_customer_placeholder
    ['#{ticket.id}', '#{ticket.id}/#{article.id}',
     '#{ticket.id}<% if @objects[:article] %>/#{article.id}<% end %>'].each do |suffix|
      body = %(<a href="\#{config.http_type}://\#{config.fqdn}/#ticket/zoom/#{suffix}" target="zammad_app">View</a><p>\#{article.body_as_html}</p>)
      result = template_factory(body).template_read(type: 'mailer', template: 'ticket_update')
      assert_equal 'unchanged subject', result[:subject]
      assert_includes result[:body], 'https://app.wasalx.example/auth/login?tenant_id=10000000-0000-4000-8000-000000000001&amp;return_to=%2Fapp%3Fview%3Dinbox%26ticket%3D#{ticket.number}'
      assert_includes result[:body], '#{article.body_as_html}'
      refute_includes result[:body], '#ticket/zoom/'
      refute_includes result[:body], '#{ticket.id}'
    end
  end

  def test_supported_ticket_templates_and_non_mail_surfaces
    body = '<a href="#{config.http_type}://#{config.fqdn}/#ticket/zoom/#{ticket.id}">View</a>'
    factory = template_factory(body)
    Wasalx::PortalMail::TICKET_TEMPLATES.each do |name|
      assert_includes factory.template_read(type: 'mailer', template: name)[:body], 'ticket%3D#{ticket.number}'
    end
    assert_equal body, factory.template_read(type: 'messaging', template: 'ticket_update')[:body]
  end

  def test_custom_template_is_preserved_and_native_links_fail_closed
    body = '<p>Custom wording</p><a href="https://app.wasalx.example/app?view=inbox">Open WasalX</a>'
    assert_equal body, template_factory(body, custom: true).template_read(type: 'mailer', template: 'ticket_create')[:body]
    unsafe = '<a href="#{config.http_type}://#{config.fqdn}/#ticket/zoom/#{ticket.id}">custom</a>'
    assert_raises(Wasalx::PortalMail::ReviewRequired) {
      template_factory(unsafe, custom: true).template_read(type: 'mailer', template: 'ticket_create')
    }
  end

  def test_unrecognized_template_contract_fails_closed
    assert_raises(Wasalx::PortalMail::ReviewRequired) {
      template_factory('<p>No known link</p>').template_read(type: 'mailer', template: 'ticket_create')
    }
  end

  def test_wrapper_preserves_reason_organization_and_message
    wrapper = File.binread(File.join(__dir__, 'fixtures/portal-mail-native/application.html.erb'))
    base = Class.new { define_method(:application_template_read) { |_data| wrapper } }
    target = Class.new(base) { prepend Wasalx::PortalMail::Templates }.new
    result = target.application_template_read(type: 'mailer', format: 'html')
    refute_includes result, '#profile/notifications'
    assert_includes result, "<%= t @objects[:reason] %>"
    assert_includes result, "<%= c 'organization' %>"
    assert_includes result, "<%= d 'message', false %>"
    assert_equal wrapper, target.application_template_read(type: 'messaging', format: 'html')
    bad = Class.new { def application_template_read(_data) = '<p>Changed upstream wrapper</p>' }
    target = Class.new(bad) { prepend Wasalx::PortalMail::Templates }.new
    assert_raises(Wasalx::PortalMail::ReviewRequired) { target.application_template_read(type: 'mailer', format: 'html') }
  end

  def test_staff_ticket_number_must_match_the_supported_inbox_contract
    base = Class.new { def template(data) = data }
    target = Class.new(base) { prepend Wasalx::PortalMail::InlineTemplates }.new
    ['0', '1&view=admin', '1' * 17, ''].each do |number|
      assert_raises(Wasalx::PortalMail::ReviewRequired) {
        target.template(template: 'ticket_create', objects: { ticket: OpenStruct.new(number: number) })
      }
    end
    data = { template: 'ticket_create', objects: { 'ticket' => OpenStruct.new(number: '1042') } }
    assert_equal data, target.template(data)
  end

  def test_inline_customer_source_cannot_reintroduce_native_links
    base = Class.new { def template(data) = data }
    target = Class.new(base) { prepend Wasalx::PortalMail::InlineTemplates }.new
    source = { templateInline: 'Reply by email to your WasalX team' }
    assert_equal source, target.template(source)
    ['https://zammad.com', 'https://case.wasalx.example/#ticket/zoom/1',
     '#{config.http_type}://#{config.fqdn}/#ticket/zoom/#{ticket.id}'].each do |value|
      assert_raises(Wasalx::PortalMail::ReviewRequired) { target.template(templateInline: value) }
    end
  end
end

module ActionController
  class API
    attr_reader :status
    def response = @response ||= OpenStruct.new(headers: {})
    def head(value) = @status = value
  end
end
module Api; module V1; end; end
module ActiveRecord
  class Base
    class << self; attr_accessor :result, :error; end
    def self.connection = self
    def self.select_value(sql)
      raise 'Unexpected query' unless sql == 'SELECT 1'
      raise error if error
      result
    end
  end
end
module Setting
  class << self; attr_accessor :initialized; end
  def self.get(key)
    raise 'Unexpected setting' unless key == 'system_init_done'
    initialized
  end
end
require_relative '../zammad-package/app/controllers/api/v1/wasalx_health_controller'

class PortalBackendHealthTest < Minitest::Test
  def teardown = ActiveRecord::Base.error = nil

  def test_database_and_initialization_are_both_required
    [[1, true, :ok], [1, false, :service_unavailable], [0, true, :service_unavailable]].each do |db, initialized, expected|
      ActiveRecord::Base.result = db
      Setting.initialized = initialized
      controller = Api::V1::WasalxHealthController.new
      controller.show
      assert_equal expected, controller.status
      assert_equal 'no-store', controller.response.headers['Cache-Control']
    end
  end

  def test_database_failure_is_unavailable_without_returning_raw_error
    ActiveRecord::Base.error = StandardError.new('private connection details')
    controller = Api::V1::WasalxHealthController.new
    controller.show
    assert_equal :service_unavailable, controller.status
  end
end

module Rails
  class << self; attr_accessor :root; end
end
class Trigger
  class << self; attr_accessor :rows, :transactions, :locks; end
  self.rows = []
  self.transactions = 0
  self.locks = 0
  def self.transaction
    self.transactions += 1
    yield
  end
  def self.where(criteria)
    selected = rows.select { |row| criteria.all? { |key, value| row.public_send(key) == value } }
    Relation.new(selected)
  end
  class Relation
    def initialize(rows) = @rows = rows
    def lock
      Trigger.locks += 1
      self
    end
    def limit(count) = Relation.new(@rows.take(count))
    def to_a = @rows
  end
end
class PortalMailReconciliationTest < Minitest::Test
  Row = Struct.new(:id, :name, :perform, :active, :condition, :updates, keyword_init: true) do
    def update!(values)
      raise 'Unexpected trigger field change' unless values.keys == [:perform]
      self.perform = values[:perform]
      self.updates += 1
    end
  end
  def teardown
    Trigger.rows = []
  end

  def seed_row(body, id: 1, active: false)
    Row.new(id: id, name: 'auto reply (on new tickets)', active: active,
      condition: { 'custom.condition' => 7 }, updates: 0,
      perform: { 'notification.email' => { 'body' => body, 'recipient' => 'custom', 'subject' => 'unchanged' } })
  end

  def test_reconciliation_locks_rows_preserves_flags_conditions_and_customizations
    body = File.binread(File.join(__dir__, 'fixtures/portal-mail-native/new-ticket-body.txt'))
    row = seed_row(body)
    custom = seed_row(body + '<p>Custom</p>', id: 2)
    custom.name = 'auto reply (on follow-up of tickets)'
    Trigger.rows = [row, custom]
    before = Marshal.load(Marshal.dump(custom))
    transactions = Trigger.transactions
    locks = Trigger.locks
    assert_equal [1], Wasalx::PortalMail.reconcile_customer_defaults!
    assert_equal false, row.active
    assert_equal({ 'custom.condition' => 7 }, row.condition)
    assert_equal 'custom', row.perform['notification.email']['recipient']
    assert_equal before, custom
    assert_equal transactions + 1, Trigger.transactions
    assert_equal locks + 3, Trigger.locks
    assert_empty Wasalx::PortalMail.reconcile_customer_defaults!
    assert_equal 1, row.updates
  end

  def test_ambiguous_seed_name_fails_before_any_row_change
    body = File.binread(File.join(__dir__, 'fixtures/portal-mail-native/new-ticket-body.txt'))
    Trigger.rows = [seed_row(body), seed_row(body, id: 2)]
    error = assert_raises(Wasalx::PortalMail::ReviewRequired) { Wasalx::PortalMail.reconcile_customer_defaults! }
    assert_equal 'WASALX_MAIL_DEFAULT_AMBIGUOUS', error.message
    assert Trigger.rows.all? { |row| row.updates.zero? }
  end

  def test_readiness_reports_custom_templates_and_active_trigger_blockers
    origin = ENV['WASALX_PORTAL_URL']
    old_root = Rails.root
    old_tenant = ENV['WASALX_TENANT_ID']
    ENV['WASALX_TENANT_ID'] = '10000000-0000-4000-8000-000000000001'
    ENV['WASALX_PORTAL_URL'] = 'https://portal.example'
    Dir.mktmpdir('wasalx-mail-contract-') do |directory|
      # Ruby on Windows can miss existing files in an absolute glob.
      Dir.chdir(directory) do
        Rails.root = Pathname.new('.')
        root = Rails.root.join('app/views/mailer')
        FileUtils.mkdir_p(root.join('ticket_create'))
        File.binwrite(root.join('application.html.erb'), File.binread(File.join(__dir__, 'fixtures/portal-mail-native/application.html.erb')))
        custom = root.join('ticket_create/en.html.erb.custom')
        File.write(custom, '<p>Custom words</p><a href="/#ticket/zoom/1">Open</a>')
        Trigger.rows = [seed_row('Customer custom /#ticket/zoom/1', active: true)]
        review = Wasalx::PortalMail.review
        assert_equal false, review[:ready]
        assert_equal 2, review[:blocked].length
        assert review[:blocked].any? { |row| row[:trigger_id] == 1 }
        assert review[:blocked].any? { |row| row[:template] == 'ticket_create' && row[:locale] == 'en' }
        assert_equal '<p>Custom words</p><a href="/#ticket/zoom/1">Open</a>', File.read(custom)
        Trigger.rows = []
        File.write(custom, '<p>Customer-owned custom text</p>')
        assert_equal({ ready: true, blocked: [] }, Wasalx::PortalMail.review)
      end
    end
  ensure
    Rails.root = old_root
    old_tenant ? ENV['WASALX_TENANT_ID'] = old_tenant : ENV.delete('WASALX_TENANT_ID')
    origin ? ENV['WASALX_PORTAL_URL'] = origin : ENV.delete('WASALX_PORTAL_URL')
  end
end
