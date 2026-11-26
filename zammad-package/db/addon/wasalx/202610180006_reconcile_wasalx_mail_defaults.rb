# SPDX-License-Identifier: AGPL-3.0-only
require Rails.root.join('lib/wasalx/portal_mail')
# Copyright (c) 2026 WasalX

class ReconcileWasalxMailDefaults
  def self.up
    Wasalx::PortalMail.reconcile_customer_defaults!
  end
  # Preserve native customization and the addon migration receipt on rollback.
  def self.down; end
end
