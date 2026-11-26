# SPDX-License-Identifier: AGPL-3.0-only
require 'cgi'
# Copyright (c) 2026 WasalX
require 'digest'
require 'uri'

module Wasalx
  module PortalMail
    class ReviewRequired < StandardError; end
    TICKET_TEMPLATES = %w[
      ticket_create ticket_update ticket_reminder_reached ticket_escalation
      ticket_escalation_warning ticket_update_merged_into
      ticket_update_received_merge ticket_article_update_reaction
    ].freeze
    SEEDS = {
      'auto reply (on new tickets)' => [
        '66b040de69a3e4865f76b32debf931b7dc22378a956a5a5dee823d078cb59e3f',
        '<div>Your request <b>(#{config.ticket_hook}#{ticket.number})</b> has been received and will be reviewed by our support staff.</div><br/><div>To provide additional information, reply to this email.</div><br/><div>Your #{config.product_name} Team</div>'
      ],
      'auto reply (on follow-up of tickets)' => [
        '1812dc976300cb17147264db805c3dba2bf3e949caa735d067e2deda50df9079',
        '<div>Your follow-up for <b>(#{config.ticket_hook}#{ticket.number})</b> has been received and will be reviewed by our support staff.</div><br/><div>To provide additional information, reply to this email.</div><br/><div>Your #{config.product_name} Team</div>'
      ],
      'customer notification (on owner change)' => [
        'bfbb5990e623fd866184a23763b6c402e6ca5bd62628b251e4dfb5436c8a0420',
        '<div>The owner of ticket <b>(#{config.ticket_hook}#{ticket.number})</b> has changed and is now "#{ticket.owner.firstname} #{ticket.owner.lastname}".</div><br/><div>To provide additional information, reply to this email.</div><br/><div>Your #{config.product_name} Team</div>'
      ]
    }.freeze
    TICKET_LINK = /href="#\{config\.http_type\}:\/\/#\{config\.fqdn\}\/#ticket\/zoom\/#\{ticket\.id\}[^"]*"/
    PREFERENCES_LINK = %q(<a href="<%= c 'http_type' %>://<%= c 'fqdn' %>/#profile/notifications"><%= t 'Manage your notification settings' %></a>).freeze
    WRAPPER_SHA256 = 'd1359f1ea6694bf456bc9d0d0de965ba5cc865c74e20d2d56962f0b10f82686a'.freeze

    def self.origin!
      uri = URI.parse(ENV.fetch('WASALX_PORTAL_URL', ''))
      secure = uri.is_a?(URI::HTTPS)
      loopback = uri.is_a?(URI::HTTP) && uri.scheme == 'http' && uri.host == '127.0.0.1'
      unless (secure || loopback) && uri.host && !uri.userinfo &&
             ['', '/'].include?(uri.path.to_s) && !uri.query && !uri.fragment &&
             uri.port.between?(1, 65_535)
        raise ReviewRequired, 'WASALX_PORTAL_MAIL_ORIGIN_INVALID'
      end
      uri.path = ''
      uri.to_s
    rescue URI::InvalidURIError
      raise ReviewRequired, 'WASALX_PORTAL_MAIL_ORIGIN_INVALID'
    end


    def self.ticket_link_source!
      tenant_id = ENV.fetch('WASALX_TENANT_ID', '')
      unless tenant_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
        raise ReviewRequired, 'WASALX_PORTAL_MAIL_TENANT_INVALID'
      end
      query = URI.encode_www_form(tenant_id: tenant_id, return_to: '/app?view=inbox&ticket=')
      CGI.escapeHTML("#{origin!}/auth/login?#{query}" + '#{ticket.number}')
    end

    def self.legacy_source?(source)
      text = source.to_s
      return true if text.match?(%r{/#(?:ticket/zoom|profile/notifications)/?}i) ||
                     text.match?(%r{https?://(?:www\.)?zammad\.com(?:[/"\s]|$)}i) || text.match?(/\bzammad\b/i)
      native = ENV.fetch('ZAMMAD_FQDN', '').downcase
      !native.empty? && text.downcase.include?("://#{native}/")
    end

    def self.require_safe_source!(source)
      raise ReviewRequired, 'WASALX_MAIL_TEMPLATE_REVIEW_REQUIRED' if legacy_source?(source)
    end

    # Change a known seed body only; keep native recipients, conditions and active flags.
    def self.seed_perform(name, perform)
      seed = SEEDS[name]
      return nil unless seed && perform.is_a?(Hash)
      notification = perform['notification.email']
      return nil unless notification.is_a?(Hash) &&
                        Digest::SHA256.hexdigest(notification['body'].to_s) == seed[0]
      perform.merge('notification.email' => notification.merge('body' => seed[1]))
    end

    def self.reconcile_customer_defaults!
      changed = []
      Trigger.transaction do
        SEEDS.each_key do |name|
          rows = Trigger.where(name: name).lock.to_a
          raise ReviewRequired, 'WASALX_MAIL_DEFAULT_AMBIGUOUS' if rows.length > 1
          row = rows.first
          next unless row
          perform = seed_perform(name, row.perform)
          next unless perform
          row.update!(perform: perform)
          changed << row.id
        end
      end
      changed
    end

    def self.review
      ticket_link_source!
      rows = Trigger.where(active: true).limit(1001).to_a
      raise ReviewRequired, 'WASALX_MAIL_REVIEW_LIMIT' if rows.length > 1000
      blocked = rows.filter_map do |row|
        body = row.perform.to_h.dig('notification.email', 'body')
        { trigger_id: row.id, code: 'WASALX_MAIL_TEMPLATE_REVIEW_REQUIRED' } if legacy_source?(body)
      end
      root = Rails.root.join('app/views/mailer')
      wrapper = File.binread(root.join('application.html.erb'))
      if Digest::SHA256.hexdigest(wrapper) != WRAPPER_SHA256
        blocked << { code: 'WASALX_MAIL_WRAPPER_CONTRACT_CHANGED' }
      end
      paths = TICKET_TEMPLATES.flat_map { |name| Dir.glob(root.join(name, '*.html.erb.custom').to_s) }
      raise ReviewRequired, 'WASALX_MAIL_REVIEW_LIMIT' if paths.length > 1000
      paths.sort.each do |path|
        raise ReviewRequired, 'WASALX_MAIL_REVIEW_LIMIT' if File.size(path) > 131_072
        next unless legacy_source?(File.binread(path))
        blocked << { template: File.basename(File.dirname(path)), locale: File.basename(path).split('.').first,
                     code: 'WASALX_MAIL_TEMPLATE_REVIEW_REQUIRED' }
      end
      { ready: blocked.empty?, blocked: blocked }
    rescue ReviewRequired => error
      { ready: false, code: error.message, blocked: [] }
    end

    module Templates
      def template_read(data)
        result = super
        return result unless data[:type] == 'mailer' && PortalMail::TICKET_TEMPLATES.include?(data[:template])
        path = send(:template_path, data)
        if path.end_with?('.custom')
          PortalMail.require_safe_source!(result.fetch(:body))
          return result
        end
        body = result.fetch(:body)
        raise ReviewRequired, 'WASALX_MAIL_TEMPLATE_CONTRACT_CHANGED' unless body.scan(PortalMail::TICKET_LINK).length == 1
        href = %(href="#{PortalMail.ticket_link_source!}")
        result.merge(body: body.gsub(PortalMail::TICKET_LINK, href).gsub('target="zammad_app"', 'target="wasalx_app"'))
      end

      def application_template_read(data)
        result = super
        return result unless data[:type] == 'mailer' && data[:format] == 'html'
        unless Digest::SHA256.hexdigest(result) == PortalMail::WRAPPER_SHA256 &&
               result.scan(PortalMail::PREFERENCES_LINK).length == 1
          raise ReviewRequired, 'WASALX_MAIL_WRAPPER_CONTRACT_CHANGED'
        end
        result.sub(PortalMail::PREFERENCES_LINK, '')
              .sub('<%= t @objects[:reason] %> |', '<%= t @objects[:reason] %>')
              .sub(%q(<% if c('organization').present? %>|), %q(<% if c('organization').present? %><% if @objects[:reason] %> | <% end %>))
      end
    end

    module InlineTemplates
      def template(data)
        PortalMail.require_safe_source!(data[:templateInline]) if data[:templateInline]
        if PortalMail::TICKET_TEMPLATES.include?(data[:template])
          objects = data[:objects].to_h
          number = (objects[:ticket] || objects['ticket'])&.number.to_s
          raise ReviewRequired, 'WASALX_PORTAL_MAIL_TICKET_INVALID' unless number.match?(/\A[1-9][0-9]{0,15}\z/)
        end
        super
      end
    end
  end
end
