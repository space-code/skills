# frozen_string_literal: true

require_relative 'test_helper'

class PricingTest < Minitest::Test
  OPTS = Pricing.options(base_territory: 'USA')
  DATA = {
    big_mac: { 'USA' => 6.0, 'BRA' => 3.0, 'JPN' => 3.0 },
    ppp: { 'USA' => 1.0, 'BRA' => 0.46, 'IND' => 0.23, 'TUR' => 0.45 },
    gni: { 'USA' => 88_000.0, 'BRA' => 10_000.0, 'IND' => 2_500.0, 'DEU' => 60_000.0 },
    band1_overrides: ['JPN'],
    tiers: { 'BRA' => 2, 'IND' => 3 }
  }.freeze

  def points(*prices)
    prices.each_with_index.map { |p, i| { 'id' => "pp#{i}", 'price' => p.to_f } }
  end

  def input(territory, equalized, pts, extra = {})
    { 'territory' => territory, 'currency' => 'XXX', 'current' => equalized, 'current_point_id' => 'old',
      'equalized' => equalized, 'available' => true, 'points' => pts }.merge(extra)
  end

  def test_gni_bands_follow_income_thresholds
    assert_equal [1.0, 'gni_bands'], Pricing.ratio_for('gni_bands', 'DEU', DATA, OPTS)
    assert_equal [0.6, 'gni_bands'], Pricing.ratio_for('gni_bands', 'BRA', DATA, OPTS)
    assert_equal [0.3, 'gni_bands'], Pricing.ratio_for('gni_bands', 'IND', DATA, OPTS)
  end

  def test_band_one_override_beats_income
    assert_equal [1.0, 'gni_bands'], Pricing.ratio_for('gni_bands', 'JPN', DATA, OPTS)
  end

  def test_big_mac_is_relative_to_the_base_territory
    ratio, source = Pricing.ratio_for('big_mac', 'BRA', DATA, OPTS)
    assert_in_delta 0.5, ratio
    assert_equal 'big_mac', source
  end

  def test_big_mac_falls_back_to_ppp_then_equalization
    assert_equal [0.45, 'ppp'], Pricing.ratio_for('big_mac', 'TUR', DATA, OPTS)
    assert_equal [1.0, 'equalization'], Pricing.ratio_for('big_mac', 'ZZZ', DATA, OPTS)
  end

  def test_missing_gni_falls_back_to_equalization
    assert_equal [1.0, 'equalization'], Pricing.ratio_for('gni_bands', 'ZZZ', DATA, OPTS)
  end

  def test_ppp_uses_a_non_us_base
    opts = Pricing.options(base_territory: 'BRA')
    ratio, = Pricing.ratio_for('ppp', 'IND', DATA, opts)
    assert_in_delta 0.5, ratio
  end

  def test_tiered_uses_tier_ratios_and_default_tier
    assert_equal [0.7, 'tiered'], Pricing.ratio_for('tiered', 'BRA', DATA, OPTS)
    assert_equal [0.4, 'tiered'], Pricing.ratio_for('tiered', 'IND', DATA, OPTS)
    assert_equal [1.0, 'tiered'], Pricing.ratio_for('tiered', 'DEU', DATA, OPTS)
  end

  def test_equalization_strategy_changes_nothing
    assert_equal [1.0, 'equalization'], Pricing.ratio_for('equalization', 'BRA', DATA, OPTS)
  end

  def test_clamp_keeps_ratio_inside_bounds
    assert_equal 0.30, Pricing.clamp_ratio(0.05, OPTS)
    assert_equal 1.30, Pricing.clamp_ratio(2.0, OPTS)
    assert_equal 0.8, Pricing.clamp_ratio(0.8, OPTS)
  end

  def test_nearest_point_and_cheaper_on_tie
    assert_equal 'pp1', Pricing.nearest_point(4.6, points(2.99, 4.99, 9.99))['id']
    assert_equal 'pp0', Pricing.nearest_point(4.0, points(3.0, 5.0))['id']
  end

  def test_row_snaps_to_a_real_price_point_and_flags_big_changes
    row = Pricing.build_row(input('IND', 1000.0, points(100, 299, 349, 999), 'current' => 999.0), 'gni_bands', DATA, OPTS)
    assert_equal 299.0, row['proposed']
    assert_equal 'gni_bands', row['ratio_source']
    assert_equal 'large-change', row['flag']
    assert_in_delta(-0.7007, row['change_pct'], 0.0001)
  end

  def test_row_marks_clamped_ratio
    data = DATA.merge(ppp: { 'USA' => 1.0, 'XXX' => 0.05 })
    row = Pricing.build_row(input('XXX', 100.0, points(30, 50, 100)), 'ppp', data, OPTS)
    assert row['clamped']
    assert_equal 0.3, row['ratio']
    assert_equal 30.0, row['proposed']
    assert_includes row['flag'], 'clamped'
  end

  def test_base_territory_keeps_its_price
    row = Pricing.build_row(input('USA', 9.99, points(4.99, 9.99, 14.99)), 'gni_bands', DATA, OPTS)
    assert_equal 'base', row['ratio_source']
    assert_equal 9.99, row['proposed']
  end

  def test_unavailable_territory_is_skipped
    row = Pricing.build_row(input('BRA', 10.0, points(5), 'available' => false), 'gni_bands', DATA, OPTS)
    assert_nil row['proposed']
    assert_equal 'unavailable', row['note']
  end

  def test_territory_without_price_points_or_equalization_is_skipped
    assert_equal 'no price points', Pricing.build_row(input('BRA', 10.0, []), 'ppp', DATA, OPTS)['note']
    assert_equal 'no equalized price', Pricing.build_row(input('BRA', nil, points(1)), 'ppp', DATA, OPTS)['note']
  end

  def test_changed_compares_point_ids
    rows = Pricing.build_proposal([input('BRA', 10.0, points(6, 10), 'current_point_id' => 'pp0')], 'gni_bands', DATA, OPTS)
    refute Pricing.changed?(rows.first)
    rows = Pricing.build_proposal([input('BRA', 10.0, points(6, 10), 'current_point_id' => 'pp1')], 'gni_bands', DATA, OPTS)
    assert Pricing.changed?(rows.first)
  end

  def test_legacy_current_point_is_resolved_by_price
    listed = points(9.99, 11.99, 14.99)
    assert_equal 'pp1', Pricing.resolve_point_id('legacy-24', 11.99, listed)
    assert_equal 'pp1', Pricing.resolve_point_id('pp1', 11.99, listed), 'a listed id is kept'
    assert_equal 'legacy-24', Pricing.resolve_point_id('legacy-24', 12.49, listed), 'no price match keeps the id'
    assert_nil Pricing.resolve_point_id(nil, nil, listed)
  end

  def test_unchanged_price_on_a_legacy_point_is_not_a_change
    listed = points(6, 10)
    resolved = Pricing.resolve_point_id('legacy', 10.0, listed)
    rows = Pricing.build_proposal([input('BRA', 10.0, listed, 'current_point_id' => resolved)], 'equalization', DATA, OPTS)
    refute Pricing.changed?(rows.first)
  end

  def test_split_entries_separates_current_from_scheduled
    entries = [
      { 'start_date' => nil, 'end_date' => '2026-01-01', 'point_id' => 'a' },
      { 'start_date' => nil, 'end_date' => nil, 'point_id' => 'b' },
      { 'start_date' => '2026-05-01', 'end_date' => nil, 'point_id' => 'c' },
      { 'start_date' => '2099-01-01', 'end_date' => nil, 'point_id' => 'd' }
    ]
    current, scheduled = Pricing.split_entries(entries, '2026-10-30')
    assert_equal 'c', current['point_id']
    assert_equal ['d'], scheduled.map { |e| e['point_id'] }
  end

  def test_csv_round_trip_and_manual_edit_resnaps
    rows = Pricing.build_proposal([input('BRA', 10.0, points(3, 6, 10), 'current' => 10.0)], 'gni_bands', DATA, OPTS)
    csv = Pricing.to_csv(rows)
    assert_equal Pricing::CSV_COLUMNS, csv.lines.first.chomp.split(',')
    edited = csv.sub(/^BRA,XXX,10\.0,10\.0,gni_bands,gni_bands,0\.6,false,6\.0,6\.0/, 'BRA,XXX,10.0,10.0,gni_bands,gni_bands,0.6,false,6.0,3.2')
    refute_equal csv, edited
    out = Pricing.apply_csv_edits(rows, edited, { 'BRA' => points(3, 6, 10) }, OPTS)
    assert_equal 3.0, out.first['proposed']
    assert_equal 'manual', out.first['ratio_source']
  end

  def test_emptied_proposed_cell_leaves_territory_unchanged
    rows = Pricing.build_proposal([input('BRA', 10.0, points(3, 6, 10), 'current' => 10.0)], 'gni_bands', DATA, OPTS)
    csv = Pricing.to_csv(rows).sub(/,6\.0,-0\.4,/, ',,-0.4,')
    out = Pricing.apply_csv_edits(rows, csv, { 'BRA' => points(3, 6, 10) }, OPTS)
    refute Pricing.changed?(out.first)
    assert_equal 'left unchanged by user', out.first['note']
  end

  def test_summary_counts
    rows = Pricing.build_proposal(
      [input('BRA', 10.0, points(6, 10), 'current' => 10.0), input('ZZZ', 10.0, [], 'current' => 10.0)],
      'gni_bands', DATA, OPTS
    )
    s = Pricing.summary(rows)
    assert_equal 2, s['territories']
    assert_equal 1, s['priced']
    assert_equal 1, s['changed']
    assert_equal 1, s['decreases']
    assert_equal 1, s['skipped']
  end
end
