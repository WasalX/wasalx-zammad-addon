# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
# Package installation triggers a Zammad application restart. On each boot (and
# each development reload), attach the package-owned concern without modifying
# Zammad's Ticket::Article source file or its native WhatsApp concern.
require Rails.root.join('lib/wasalx/portal_upload_expiry')
require Rails.root.join('lib/wasalx/client')
require Rails.root.join('lib/wasalx/service_identity')
require Rails.root.join('lib/wasalx/installed_package')
require Rails.root.join('lib/wasalx/membership_projection')
require Rails.root.join('lib/wasalx/session_assurance')
require Rails.root.join('lib/wasalx/session_refresh')
require Rails.root.join('lib/wasalx/session_state')
require Rails.root.join('lib/wasalx/membership_access')
require Rails.root.join('lib/wasalx/routing_configuration')

Rails.application.config.to_prepare do
  expiry = Wasalx::PortalUploadExpiry::Cleanup
  UploadCacheCleanupJob.prepend(expiry) unless UploadCacheCleanupJob < expiry
  Wasalx::SessionRefresh.protect_models!
  # Include in the existing concerns' super chains, including on reload after
  # they were prepended. A rejected native save cannot enroll a pending grant.
  Wasalx::SessionRefresh::Store.include(Wasalx::SessionState::Store) unless Wasalx::SessionRefresh::Store < Wasalx::SessionState::Store
  Wasalx::SessionAssurance::OidcVerification.include(Wasalx::SessionState::Oidc) unless Wasalx::SessionAssurance::OidcVerification < Wasalx::SessionState::Oidc

  article_concern = Ticket::Article::EnqueueCommunicateWasalxJob
  Ticket::Article.include(article_concern) if !(Ticket::Article < article_concern)
  message_id_concern = Ticket::Article::NormalizeWasalxMessageId
  Ticket::Article.prepend(message_id_concern) if !(Ticket::Article < message_id_concern)
  ticket_concern = Ticket::EnqueueWasalxTicketStateJob
  Ticket.include(ticket_concern) if !(Ticket < ticket_concern)
  mobile_ticket_concern = Taskbar::EnqueueWasalxDirectTicketReadJob
  Taskbar.include(mobile_ticket_concern) unless Taskbar < mobile_ticket_concern
  {
    ActionDispatch::Session::ActiveRecordStore => Wasalx::SessionRefresh::Store,
    Auth::User => Wasalx::ServiceIdentity::PasswordAuthentication,
    User.singleton_class => Wasalx::ServiceIdentity::Recovery,
    ApplicationController => Wasalx::MembershipAccess::Authentication,
    ApplicationCable::Connection => Wasalx::MembershipAccess::CableConnection,
    GraphqlChannel => Wasalx::MembershipAccess::CableChannel,
    Sessions::Event.singleton_class => Wasalx::MembershipAccess::LegacyEvents,
    Sessions.singleton_class => Wasalx::MembershipAccess::LegacyTransport,
    Sessions::Event::Base => Wasalx::MembershipAccess::LegacyDirectTransport,
    WebsocketServer.singleton_class => Wasalx::MembershipAccess::LegacyDirectTransport,
    Authorization.singleton_class => Wasalx::MembershipAccess::OidcCreation,
    OmniAuth::Strategies::OidcDatabase => Wasalx::SessionAssurance::OidcVerification,
    SessionsController => Wasalx::SessionAssurance::OidcCallback,
    Sessions::Event::Login => Wasalx::SessionAssurance::LegacyLogin,
  }.each { |target, concern| target.prepend(concern) unless target < concern }
  {
    User => Wasalx::ServiceIdentity::UserCredentials,
    Authorization => Wasalx::ServiceIdentity::HumanCredential,
    User::TwoFactorPreference => Wasalx::ServiceIdentity::HumanCredential,
    Token => Wasalx::ServiceIdentity::TokenCredential,
  }.each { |target, concern| target.include(concern) unless target < concern }
end
