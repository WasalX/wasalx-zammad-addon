# SPDX-License-Identifier: AGPL-3.0-only
class WasalxMembership < ActiveRecord::Base
# Copyright (c) 2026 WasalX
  self.table_name = 'wasalx_memberships'
  belongs_to :user, optional: true
end
