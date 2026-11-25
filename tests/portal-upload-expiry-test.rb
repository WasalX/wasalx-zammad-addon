# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 WasalX
require 'minitest/autorun'
require_relative '../zammad-package/lib/wasalx/portal_upload_expiry'
require_relative '../zammad-package/db/addon/wasalx/202610180004_schedule_portal_upload_expiry'

class Store
  def self.connection; self; end
  def self.execute(value); @last_query = value; end
  def self.last_query; @last_query; end
end
class Scheduler
  class << self
    attr_accessor :row
    def find_by(method:)
      raise 'Changed native job identity' unless method == 'UploadCacheCleanupJob.perform_now'
      row
    end
  end
end
class PortalUploadExpiryTest < Minitest::Test
  Item = Struct.new(:preferences, :created_at, :updated_at)
  Schedule = Struct.new(:active, :period, :changes) do
    def update!(attributes); self.changes = attributes; self.period = attributes.fetch(:period); end
  end
  E = Wasalx::PortalUploadExpiry
  def test_one_hour_boundary_uses_creation_time_without_changing_legacy_caches
    now = Time.utc(2026,10,18,12)
    marker = { 'Wasalx-Portal-Target' => { 'kind' => 'GROUP', 'id' => 'synthetic' } }
    assert E.fresh?(Item.new(marker, now - 3599, now), now: now)
    refute E.fresh?(Item.new(marker, now - 3600, now), now: now)
    refute E.fresh?(Item.new(marker, now - 7200, now), now: now)
    refute E.fresh?(Item.new(marker, nil, now), now: now)
    assert E.fresh?(Item.new({ 'Content-Type' => 'image/png' }, now - 7200, now), now: now)
    assert E.marked?(Item.new(marker, now, now))
    refute E.marked?(Item.new({ 'note' => 'Wasalx-Portal-Target' }, now, now))
  end
  def test_cleanup_and_admission_share_the_actor_cache_lock
    E.lock!(17, 'synthetic-cache')
    expected = Digest::SHA256.hexdigest('wasalx:portal-upload:17:synthetic-cache')[0,15].to_i(16)
    assert_equal "SELECT pg_advisory_xact_lock(#{expected})", Store.last_query
    E.lock!(18, 'synthetic-cache')
    refute_equal "SELECT pg_advisory_xact_lock(#{expected})", Store.last_query
  end
  def test_existing_native_job_behavior_runs_before_the_scoped_extension
    events=[]
    klass=Class.new { define_method(:perform) { events << :native } }
    klass.prepend(E::Cleanup)
    original=E.method(:cleanup!)
    E.define_singleton_method(:cleanup!) { events << :portal }
    klass.new.perform
    assert_equal [:native,:portal],events
  ensure
    E.define_singleton_method(:cleanup!,original) if original
  end
  def test_migration_reuses_only_the_existing_active_job_without_slowing_faster_schedules
    Scheduler.row=Schedule.new(true,30*86400,nil)
    SchedulePortalUploadExpiry.up
    assert_equal({period:600,updated_by_id:1},Scheduler.row.changes)
    Scheduler.row=Schedule.new(true,300,nil)
    SchedulePortalUploadExpiry.up
    assert_nil Scheduler.row.changes
    [nil,Schedule.new(false,600,nil),Schedule.new(true,0,nil)].each do |invalid|
      Scheduler.row=invalid
      assert_raises(RuntimeError) { SchedulePortalUploadExpiry.up }
    end
  end
end
