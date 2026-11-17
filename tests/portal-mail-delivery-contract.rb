# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'minitest/autorun'
require 'ostruct'
require_relative '../zammad-package/lib/wasalx/portal_mail_delivery'
class PortalMailDeliveryContract < Minitest::Test
  def article_record(preferences={},internal:false,sender:'Agent',type:'email')
    OpenStruct.new(preferences:preferences,internal:internal,sender:OpenStruct.new(name:sender),type:OpenStruct.new(name:type))
  end
  def project(value); Wasalx::PortalMailDelivery.article(value); end
  def recipient(preferences,today:Date.new(2026,10,18))
    user=OpenStruct.new(preferences:preferences)
    user.define_singleton_method(:save!){raise 'read projection must never save'}
    before=Marshal.dump(user.preferences)
    result=Wasalx::PortalMailDelivery.recipient(user,today:today)
    assert_equal before,Marshal.dump(user.preferences)
    result
  end
  def test_native_success_means_mail_server_sent_not_recipient_delivered
    result=project(article_record({'delivery_status'=>'success','delivery_retry'=>4,'delivery_status_message'=>'PRIVATE'}))
    assert_equal({state:'SENT',attempts:4,automatic_attempts_ended:false,notice:false},result)
    refute_includes result.to_s,'PRIVATE'
  end
  def test_native_system_email_has_the_same_read_only_delivery_contract
    assert_equal 'SENT',project(article_record({'delivery_status'=>'success'},sender:'System'))[:state]
  end
  def test_absent_or_unrecognized_result_is_unconfirmed_not_queued_or_sent
    [nil,'pending','private-error'].each do |status|
      assert_equal 'UNCONFIRMED',project(article_record({'delivery_status'=>status}))[:state]
    end
  end
  def test_native_failures_do_not_claim_definitive_rejection_or_promise_retry
    [1,3,4].each do |attempts|
      result=project(article_record({'delivery_status'=>'fail','delivery_retry'=>attempts}))
      assert_equal 'UNCONFIRMED',result[:state]
      assert_equal attempts>=4,result[:automatic_attempts_ended]
      refute result.key?(:can_retry)
    end
  end
  def test_invalid_attempt_count_is_not_coerced
    ['4',-1,1_000_001,nil].each{|attempts|assert_nil project(article_record({'delivery_retry'=>attempts}))[:attempts]}
  end
  def test_incoming_or_internal_notes_are_not_outbound_mail_status
    assert_nil project(article_record({},sender:'Customer'))
    assert_nil project(article_record({},internal:true))
    assert_nil project(article_record({},type:'note'))
  end
  def test_native_delivery_notice_is_safe_metadata_and_its_raw_message_is_hidden
    value=article_record({'delivery_message'=>true,'delivery_status_message'=>'PRIVATE'},internal:true,sender:'System',type:'note')
    assert Wasalx::PortalMailDelivery.notice?(value)
    assert_equal({state:'UNCONFIRMED',attempts:nil,automatic_attempts_ended:true,notice:true},project(value))
    refute Wasalx::PortalMailDelivery.notice?(article_record({'delivery_message'=>true},sender:'Customer'))
  end
  def test_bounce_is_current_recipient_state_not_original_article_failure
    state=recipient({mail_delivery_failed:true,mail_delivery_failed_data:Date.new(2026,10,18)})
    assert_equal({state:'RECENT_FAILURE',reason:'BOUNCE_OR_DELIVERY_FAILURE'},state)
    assert_equal 'SENT',project(article_record({'delivery_status'=>'success'}))[:state]
  end
  def test_exact_native61day_window_and_invalid_address_reason_are_read_only
    assert_equal 'RECENT_FAILURE',recipient({mail_delivery_failed:true,mail_delivery_failed_data:Date.new(2026,8,19)})[:state]
    assert_equal 'CLEAR',recipient({mail_delivery_failed:true,mail_delivery_failed_data:Date.new(2026,8,18)})[:state]
    assert_equal 'INVALID_ADDRESS',recipient({mail_delivery_failed:true,mail_delivery_failed_data:'2026-10-18',mail_delivery_failed_reason:'invalid email'})[:reason]
  end
  def test_malformed_or_future_failure_date_remains_unconfirmed
    [nil,'not a date','2027-01-01'].each{|date|assert_equal 'UNCONFIRMED',recipient({mail_delivery_failed:true,mail_delivery_failed_data:date})[:state]}
    assert_equal 'CLEAR',recipient({mail_delivery_failed:false})[:state]
  end
end
