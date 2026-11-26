# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
# Copyright (c) 2026 WasalX

module Wasalx
  module PortalUploadExpiry
    RETENTION = 3600
    MARKER = 'Wasalx-Portal-Target'.freeze

    def self.marked?(store)
      store.preferences.is_a?(Hash) && store.preferences.key?(MARKER)
    end

    def self.fresh?(store, now: Time.now)
      !marked?(store) || (store.created_at && store.created_at > now - RETENTION && store.created_at <= now)
    end

    def self.lock!(actor_id, cache_id)
      key = "wasalx:portal-upload:#{actor_id}:#{cache_id}"
      Store.connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest(key)[0, 15].to_i(16)})")
    end

    def self.cleanup!
      object_id = Store::Object.lookup(name: 'UploadCache')&.id
      return unless object_id
      cutoff = Time.now - RETENTION
      Store.where(store_object_id: object_id).where('created_at <= ?', cutoff)
        .where('preferences LIKE ?', "%#{MARKER}%").in_batches do |batch|
        batch.pluck(:id).each do |id|
          Store.transaction do
            candidate = Store.find_by(id: id, store_object_id: object_id)
            next unless candidate
            lock!(candidate.created_by_id, candidate.o_id)
            store = Store.lock.find_by(id: id, store_object_id: object_id)
            next unless store && marked?(store) && !fresh?(store)
            Store.remove_item(store.id)
          end
        end
      end
    end

    module Cleanup
      def perform
        super
        Wasalx::PortalUploadExpiry.cleanup!
      end
    end
  end
end
