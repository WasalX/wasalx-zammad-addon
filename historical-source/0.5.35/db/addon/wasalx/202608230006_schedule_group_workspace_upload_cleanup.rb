# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class ScheduleGroupWorkspaceUploadCleanup
  METHOD = 'WasalxGroupWorkspaceUploadCleanupJob.perform_now'

  def self.up
    UserInfo.current_user_id = 1
    Scheduler.create_if_not_exists(
      name: 'Delete expired WasalX group uploads.',
      method: METHOD,
      period: 1.day,
      prio: 2,
      active: true,
      updated_by_id: 1,
      created_by_id: 1
    )
  end

  def self.down
    Scheduler.find_by(method: METHOD)&.update(active: false, updated_by_id: 1)
  end
end
