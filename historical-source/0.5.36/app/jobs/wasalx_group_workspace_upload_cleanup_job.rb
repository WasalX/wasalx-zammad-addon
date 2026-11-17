# SPDX-License-Identifier: AGPL-3.0-only

# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
class WasalxGroupWorkspaceUploadCleanupJob < ApplicationJob
  # Browser-to-control retries finish within hours. Seven days keeps a
  # deliberately conservative recovery margin without retaining abandoned
  # package stages indefinitely.
  RETENTION = 7.days
  OBJECT_NAME = 'Wasalx::GroupWorkspaceUpload'

  def perform
    object_id = Store::Object.lookup(name: OBJECT_NAME)&.id
    return if object_id.blank?

    cutoff = RETENTION.ago
    Store.where(store_object_id: object_id).where('updated_at < ?', cutoff).in_batches do |batch|
      batch.pluck(:id).each { |store_id| remove_if_expired(store_id, object_id, cutoff) }
    end
  end

  private

  def remove_if_expired(store_id, object_id, cutoff)
    Store.transaction do
      store = Store.lock.find_by(id: store_id, store_object_id: object_id)
      next if !store || store.updated_at >= cutoff

      Store.remove_item(store.id)
    end
  end
end
