# SPDX-License-Identifier: AGPL-3.0-only
class AddTenantServiceIdentity
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  def self.up
    %w[wasalx_service wasalx_privacy].each do |name|
      Permission.create_if_not_exists(name: name, label: 'Tenant automation', description: 'Governed noninteractive tenant integration', preferences: {})
    end
    Setting.create_if_not_exists(
      title: 'Tenant automation identity', name: 'wasalx_service_identity', area: 'Integration::Wasalx',
      description: 'Governed native token ownership receipt', options: {}, state: nil,
      preferences: { permission: ['admin.system'] }, frontend: false
    )
  end

  def self.down
    # Revoking this package would remove mandatory access fences. Never erase a
    # committed ownership receipt or restore the retired human automatically.
    raise 'Tenant service identity handover requires reviewed rollback' if Wasalx::ServiceIdentity.handover_evidence?
  end
end
