# frozen_string_literal: true

require_relative 'test_helper'
require 'schedule'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class ScheduleTest < Minitest::Test
  TODAY = Date.new(2026, 10, 30)
  START = '2026-11-15'
  SCRIPT = File.expand_path('../scripts/schedule_body.rb', __dir__)

  def row(territory, new_point, current_point)
    { 'territory' => territory, 'price_point_id' => new_point, 'current_point_id' => current_point }
  end

  def rows
    [row('USA', 'usa-new', 'usa-old'), row('DEU', 'deu-same', 'deu-same'), row('BRA', 'bra-new', nil), row('ZZZ', nil, nil)]
  end

  def build(kind, start_date = nil, input = rows)
    Schedule.body(kind: kind, product_id: '77', base: 'USA', rows: input, start_date: start_date, today: TODAY)
  end

  def prices(body)
    body['included'].map { |i| [i['relationships'].values.first['data']['id'], i['attributes']['startDate'], i['attributes']['endDate']] }
  end

  def test_immediate_app_body_has_one_price_per_priced_territory
    body = build('app')
    assert_equal 'appPriceSchedules', body['data']['type']
    assert_equal 'USA', body['data']['relationships']['baseTerritory']['data']['id']
    assert_equal '77', body['data']['relationships']['app']['data']['id']
    assert_equal [['usa-new', nil, nil], ['deu-same', nil, nil], ['bra-new', nil, nil]], prices(body)
  end

  def test_manual_prices_reference_every_included_price
    body = build('app', START)
    refs = body['data']['relationships']['manualPrices']['data']
    assert_equal body['included'].map { |i| i['id'] }, refs.map { |r| r['id'] }
    assert_equal body['included'].size, refs.map { |r| r['id'] }.uniq.size
    assert(refs.all? { |r| r['type'] == 'appPrices' })
  end

  def test_dated_app_body_keeps_the_current_price_until_the_start_date
    assert_equal [['usa-old', nil, START], ['usa-new', START, nil], ['deu-same', nil, nil], ['bra-new', START, nil]],
                 prices(build('app', START))
  end

  def test_dated_iap_body_uses_a_start_date_pair
    body = build('iap', START)
    assert_equal 'inAppPurchasePriceSchedules', body['data']['type']
    assert_equal 'inAppPurchases', body['data']['relationships']['inAppPurchase']['data']['type']
    assert_equal [['usa-old', nil, nil], ['usa-new', START, nil], ['deu-same', nil, nil], ['bra-new', START, nil]],
                 body['included'].map { |i| [i['relationships']['inAppPurchasePricePoint']['data']['id'], i['attributes']['startDate'], i['attributes']['endDate']] }
    refute(body['included'].any? { |i| i['attributes'].key?('endDate') }, 'IAP prices have no endDate in Apple\'s example')
  end

  def test_iap_prices_name_their_product
    price = build('iap').fetch('included').first
    assert_equal 'inAppPurchasePrices', price['type']
    assert_equal '77', price['relationships']['inAppPurchaseV2']['data']['id']
  end

  def test_unchanged_territories_get_one_immediate_price_even_with_a_start_date
    assert_equal [['deu-same', nil, nil]], prices(build('app', START, [row('DEU', 'deu-same', 'deu-same')]))
  end

  def test_skipped_rows_keep_their_current_point
    skipped = { 'territory' => 'ZZZ', 'price_point_id' => 'zzz-keep', 'current_point_id' => 'zzz-keep', 'ratio_source' => nil }
    assert_equal [['zzz-keep', nil, nil]], prices(build('app', START, [skipped]))
  end

  def test_rows_without_a_price_point_are_left_out
    assert_empty build('app', nil, [row('ZZZ', nil, nil)])['included']
  end

  def test_the_start_date_must_be_after_today
    [TODAY.to_s, '2026-10-01'].each do |date|
      error = assert_raises(ArgumentError) { build('app', date) }
      assert_includes error.message, 'after'
    end
  end

  def test_a_malformed_start_date_is_rejected
    assert_includes assert_raises(ArgumentError) { build('app', '15.11.2026') }.message, 'YYYY-MM-DD'
  end

  def test_unknown_kind_is_rejected
    assert_raises(ArgumentError) { build('subscription') }
  end

  # ---- the command line ----------------------------------------------------

  def with_proposal
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'proposal.json')
      File.write(path, JSON.generate('meta' => { 'base_territory' => 'USA' }, 'rows' => rows))
      yield path
    end
  end

  def test_cli_prints_the_body_and_summarises_on_stderr
    with_proposal do |path|
      out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--proposal', path, '--kind', 'app', '--id', '77')
      assert status.success?, err
      assert_equal 3, JSON.parse(out)['included'].size
      assert_includes err, '3 price entries'
    end
  end

  def test_cli_rejects_a_past_start_date
    with_proposal do |path|
      _, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--proposal', path, '--kind', 'iap', '--id', '77', '--start-date', '2020-01-01')
      refute status.success?
      assert_includes err, 'after'
    end
  end
end
