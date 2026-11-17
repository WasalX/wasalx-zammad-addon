# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'minitest/autorun'
require 'ostruct'
require 'pathname'

module Rails
  def self.root
    Pathname.new(File.expand_path('../zammad-package', __dir__))
  end

  def self.application
    @application ||= OpenStruct.new(config: MailboxInitializerConfig.new)
  end
end

class MailboxInitializerConfig
  attr_accessor :filter_parameters
  attr_reader :callbacks

  def initialize
    @filter_parameters = [:existing]
    @callbacks = []
  end

  def to_prepare(&block)
    @callbacks << block
  end
end

class MailboxInitializerContractTest < Minitest::Test
  def native_models
    channel = Class.new do
      class << self
        attr_accessor :filter_attributes, :draft
        def find_by(id:)
          draft if id == 1
        end
      end
      self.filter_attributes = [:existing]
    end
    smtp = Class.new do
      private

      def prepare_bcc_header(_attributes)
        ['ordinary-bcc']
      end

      def build_smtp_params(_options)
        { enable_starttls_auto: true }
      end
    end
    driver = Module.new
    driver.const_set(:Smtp, smtp)
    channel.const_set(:Driver, driver)
    Object.const_set(:Channel, channel)
    Object.const_set(:EmailAddress, Class.new do
      attr_accessor :channel_id

      private

      def update_email_address_id
        :native_group_assignment
      end
    end)
    smtp
  end

  def assert_prepared(smtp)
    assert_equal [:existing, :options], Channel.filter_attributes
    assert_equal 1, smtp.ancestors.count(Wasalx::RequiredSmtpTLS)
    assert_equal 1, EmailAddress.ancestors.count(Wasalx::MailboxAddressDraft)
    assert_equal smtp, Wasalx::MailboxVerificationSmtp.superclass
    assert_equal ['ordinary-bcc'], smtp.new.send(:prepare_bcc_header, {})
    assert_nil Wasalx::MailboxVerificationSmtp.new.send(:prepare_bcc_header, {})

    options = { wasalx_require_starttls: true, ssl: false, ssl_verify: true, openssl_verify_mode: 'peer' }
    assert_equal({ enable_starttls: :always }, smtp.new.send(:build_smtp_params, options))
    assert_equal({ enable_starttls_auto: true }, smtp.new.send(:build_smtp_params, {}))
    assert_raises(ArgumentError) { smtp.new.send(:build_smtp_params, options.merge(ssl_verify: false)) }
    assert_raises(ArgumentError) { smtp.new.send(:build_smtp_params, options.merge(ssl: true)) }

    Channel.draft = OpenStruct.new(active: false, preferences: { 'wasalx_mail_revision' => 1 })
    address = EmailAddress.new
    address.channel_id = 1
    assert_nil address.send(:update_email_address_id)
    Channel.draft.active = true
    assert_equal :native_group_assignment, address.send(:update_email_address_id)
  end

  def test_cold_registration_and_reload_attach_current_native_models
    refute Object.const_defined?(:Channel, false)
    refute Object.const_defined?(:EmailAddress, false)
    load Rails.root.join('config/initializers/wasalx_mailbox_administration.rb')
    config = Rails.application.config
    assert_equal [:existing, :input], config.filter_parameters
    assert_equal 1, config.callbacks.length
    refute Object.const_defined?(:Channel, false)
    refute Object.const_defined?(:EmailAddress, false)
    refute Wasalx.const_defined?(:MailboxVerificationSmtp, false)

    probe_path = Rails.root.join('app/models/wasalx/mailbox_verification_smtp.rb').to_s
    first_smtp = native_models
    Wasalx.autoload(:MailboxVerificationSmtp, probe_path)
    2.times { config.callbacks.each(&:call) }
    assert_prepared(first_smtp)
    first_probe = Wasalx::MailboxVerificationSmtp

    # Model unloading removes its loaded feature before registering the next autoload.
    Wasalx.send(:remove_const, :MailboxVerificationSmtp)
    $LOADED_FEATURES.delete(probe_path)
    Object.send(:remove_const, :Channel)
    Object.send(:remove_const, :EmailAddress)
    next_smtp = native_models
    Wasalx.autoload(:MailboxVerificationSmtp, probe_path)
    2.times { config.callbacks.each(&:call) }
    assert_prepared(next_smtp)
    refute_equal first_smtp, next_smtp
    refute_equal first_probe, Wasalx::MailboxVerificationSmtp
  end
end
