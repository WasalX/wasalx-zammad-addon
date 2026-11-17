# SPDX-License-Identifier: AGPL-3.0-only
class SchedulePortalUploadExpiry
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
  def self.up
    scheduler = Scheduler.find_by(method: 'UploadCacheCleanupJob.perform_now')
    raise 'Native upload cleanup prerequisite is unavailable' unless scheduler && scheduler.active && scheduler.period.to_i.positive?
    return if scheduler.period <= 600
    scheduler.update!(period: 600, updated_by_id: 1)
  end

  # Preserve expiry cleanup and do not overwrite later operator scheduling choices.
  def self.down; end
end
