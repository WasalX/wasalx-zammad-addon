# SPDX-License-Identifier: AGPL-3.0-only
require 'uri'
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>

module Wasalx
  # Executed by the existing native init job, never by the long-lived API token.
  module BootstrapSettings
    def self.apply!
      require_relative 'portal_mail'
      PortalMail.reconcile_customer_defaults!
      issuer = ENV.fetch('WASALX_BOOTSTRAP_OIDC_ISSUER', '')
      client = ENV.fetch('WASALX_BOOTSTRAP_OIDC_CLIENT_ID', '')
      group_name = ENV.fetch('WASALX_BOOTSTRAP_INITIAL_GROUP', '')
      return if [issuer, client, group_name].all?(&:empty?) # Existing local setup remains compatible.
      raise 'Native setup configuration is incomplete' if [issuer, client, group_name].any?(&:empty?)
      uri = URI.parse(issuer)
      raise 'Native OIDC issuer is invalid' unless %w[https http].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
      raise 'Native setup configuration is invalid' if [client, group_name].any? { |value| value.length > 250 || value.match?(/[[:cntrl:]]/) }
      desired = { display_name: 'WasalX SSO', identifier: client, issuer: issuer.delete_suffix('/'), uid_field: 'sub', scope: 'openid email profile', pkce: true }
      Setting.transaction do
        { 'auth_openid_connect_credentials' => desired, 'auth_openid_connect' => true, 'user_show_password_login' => false }.each do |name, value|
          raise 'Native setting is missing' unless Setting.exists?(name: name)
          Setting.set(name, value)
        end
        group = Group.find_or_initialize_by(name: group_name)
        group.assign_attributes(active: true, created_by_id: group.created_by_id || 1, updated_by_id: 1)
        group.save!
      end
    end
  end
end
