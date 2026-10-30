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

  def test_unavailable_territory_is_skipped_and_keeps_its_price
    row = Pricing.build_row(input('BRA', 10.0, points(5), 'available' => false, 'current_point_id' => 'pp-manual'),
                            'gni_bands', DATA, OPTS)
    assert Pricing.skipped?(row)
    assert_equal 'unavailable', row['note']
    assert_equal 'pp-manual', row['price_point_id'], 'the schedule must not drop a manual price'
    assert_equal 10.0, row['proposed']
    refute Pricing.changed?(row)
  end

  def test_every_skip_reason_keeps_the_current_price
    [input('BRA', 10.0, []), input('BRA', nil, points(1)), input('BRA', 10.0, points(5), 'available' => false)].each do |i|
      row = Pricing.build_row(i.merge('current_point_id' => 'keep'), 'ppp', DATA, OPTS)
      assert_equal 'keep', row['price_point_id'], row['note']
      refute Pricing.changed?(row), row['note']
    end
  end

  def test_a_skipped_row_without_a_current_price_has_nothing_to_keep
    row = Pricing.build_row(input('BRA', 10.0, [], 'current' => nil, 'current_point_id' => nil), 'ppp', DATA, OPTS)
    assert_nil row['price_point_id']
    assert Pricing.skipped?(row)
  end

  def test_the_base_price_is_never_clamped
    opts = Pricing.options(clamp_max: 0.9)
    row = Pricing.build_row(input('USA', 9.99, points(8.99, 9.99)), 'gni_bands', DATA, opts)
    assert_equal 9.99, row['proposed']
    refute row['clamped']
    assert_equal 1.0, row['ratio']
  end

  def test_parse_price_reads_locale_formats
    {
      '9,90' => 9.9, '$4.99' => 4.99, '1,299.00' => 1299.0, '1.299,00' => 1299.0,
      '1 299' => 1299.0, '1,299' => 1299.0, '12,5' => 12.5, '9990' => 9990.0, '₹499' => 499.0
    }.each { |raw, price| assert_equal price, Pricing.parse_price(raw), raw }
    ['abc', '', '0', '-', nil].each { |raw| assert_nil Pricing.parse_price(raw), raw.inspect }
  end

  def test_a_comma_decimal_edit_is_applied
    rows = Pricing.build_proposal([input('BRA', 10.0, points(3, 6, 10), 'current' => 10.0)], 'gni_bands', DATA, OPTS)
    csv = Pricing.to_csv(rows).sub(/,6\.0,-0\.4,/, ',"3,2",-0.4,')
    out = Pricing.apply_csv_edits(rows, csv, { 'BRA' => points(3, 6, 10) }, OPTS)
    assert_equal 3.0, out.first['proposed']
  end

  # sets the `proposed` cell of the given territories in a proposal.csv
  def edit_csv(rows, edits)
    table = CSV.parse(Pricing.to_csv(rows), headers: true)
    table.each { |r| r['proposed'] = edits[r['territory']] if edits.key?(r['territory']) }
    table.to_csv
  end

  def test_unreadable_edits_raise_with_every_territory_named_and_change_nothing
    inputs = [input('BRA', 10.0, points(3, 6, 10), 'current' => 10.0), input('IND', 10.0, points(3, 6, 10), 'current' => 10.0)]
    rows = Pricing.build_proposal(inputs, 'gni_bands', DATA, OPTS)
    csv = edit_csv(rows, 'BRA' => 'abc', 'IND' => 'n/a')
    error = assert_raises(Pricing::EditError) { Pricing.apply_csv_edits(rows, csv, { 'BRA' => points(3, 6, 10) }, OPTS) }
    assert_equal ["BRA: 'abc'", "IND: 'n/a'"], error.problems
  end

  def test_an_emptied_cell_leaves_no_stale_numbers
    rows = Pricing.build_proposal([input('BRA', 10.0, points(3, 6, 10), 'current' => 10.0)], 'gni_bands', DATA, OPTS)
    csv = Pricing.to_csv(rows).sub(/,6\.0,-0\.4,/, ',,-0.4,')
    row = Pricing.apply_csv_edits(rows, csv, { 'BRA' => points(3, 6, 10) }, OPTS).first
    assert_equal 0.0, row['change_pct']
    assert_equal '', row['flag']
    assert_nil row['target']
    assert_equal 'unchanged', row['ratio_source']
  end

  def test_a_manual_edit_drops_the_clamped_flag
    data = DATA.merge(ppp: { 'USA' => 1.0, 'XXX' => 0.05 })
    rows = Pricing.build_proposal([input('XXX', 100.0, points(30, 50, 100))], 'ppp', data, OPTS)
    assert rows.first['clamped']
    csv = Pricing.to_csv(rows).sub(/,30\.0,-0\.7,/, ',50,-0.7,')
    row = Pricing.apply_csv_edits(rows, csv, { 'XXX' => points(30, 50, 100) }, OPTS).first
    refute row['clamped']
    refute_includes row['flag'], 'clamped'
    assert_equal 50.0, row['target']
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

  # ---- price endings ------------------------------------------------------

  CHARM = Pricing.options(endings: 'charm', endings_rules: {
                            'BRL' => { 'unit' => 100, 'mod' => 100, 'endings' => [90, 99] },
                            'JPY' => { 'unit' => 1, 'mod' => 100, 'endings' => [80, 0] },
                            'MXN' => { 'unit' => 1, 'mod' => 10, 'endings' => [9] }
                          })

  def pick(target, prices, currency, opts = CHARM)
    point, note = Pricing.pick_point(target, points(*prices), currency, opts)
    [point['price'], note]
  end

  def test_endings_none_keeps_the_nearest_point
    assert_equal 6.88, pick(6.9, [6.88, 6.99, 7.05], 'USD', Pricing.options)[0]
  end

  def test_charm_prefers_a_99_ending_over_a_nearer_plain_price
    assert_equal [6.99, ''], pick(6.9, [6.88, 6.99, 7.05], 'USD')
  end

  def test_charm_accepts_49_as_well_as_99
    assert_equal 7.49, pick(7.5, [7.4, 7.49, 7.6], 'EUR')[0]
  end

  def test_charm_uses_the_local_convention_in_brazil
    assert_equal 64.9, pick(64.7, [64.5, 64.9, 65.0, 66.0], 'BRL')[0], 'BRL likes .90, not .00'
    assert_equal 64.99, pick(64.7, [64.5, 64.99, 65.0], 'BRL')[0]
  end

  def test_charm_in_japan_prefers_80_or_00_endings
    prices = (150..160).map { |i| i * 10 }
    assert_equal 1500, pick(1530, prices, 'JPY')[0]
    assert_equal 1580, pick(1570, prices, 'JPY')[0]
  end

  def test_charm_in_mexico_prefers_prices_ending_in_9
    assert_equal 249, pick(247, [240, 245, 249, 250], 'MXN')[0]
  end

  def test_whole_number_currency_without_a_rule_prefers_round_numbers
    prices = (160..170).map { |i| i * 10 }
    assert_equal 1600, pick(1630, prices, 'XYZ')[0], 'two significant digits'
  end

  def test_charm_stays_inside_the_tolerance
    price, note = pick(7.0, [6.5, 7.3, 7.9], 'USD')
    assert_equal 7.3, price, 'nearest wins when nothing nice is within 5%'
    assert_equal 'no charm ending within 5%', note
    assert_equal 6.99, pick(7.0, [6.99, 7.3], 'USD', Pricing.options(CHARM.merge(endings_tolerance: 0.01)))[0]
  end

  def test_charm_may_dip_below_the_clamp_floor_within_the_tolerance
    # band 3 sits exactly on the clamp floor; the nice 3.49 just below a 3.60 target must still be reachable
    assert_equal [3.49, ''], pick(3.6, [3.49, 3.59, 3.69], 'USD')
  end

  def test_charm_leaves_the_base_territory_alone
    pts = points(9.99, 10.0, 10.49)
    row = Pricing.build_row(input('USA', 10.0, pts, 'current' => 10.0), 'gni_bands', DATA, CHARM)
    assert_equal 10.0, row['proposed']
    assert_equal 'base', row['ratio_source']
  end

  def test_charm_in_a_full_row
    row = Pricing.build_row(input('BRA', 79.9, points(34.9, 47.0, 47.9, 49.9, 79.9), 'currency' => 'BRL'), 'gni_bands', DATA, CHARM)
    assert_equal 47.9, row['proposed'], 'target 47.94: 47.90 is nice for BRL and nearest'
    assert_equal '', row['note']
  end

  # The shipped rules file must make sense on the price points Apple really lists.
  SHIPPED = Pricing.options(endings: 'charm',
                            endings_rules: JSON.parse(File.read(File.expand_path('../references/data/endings.json', __dir__)))['currencies'])

  def test_shipped_rules_match_local_conventions
    assert_equal 17.98, pick(17.9, [17.5, 17.9, 17.95, 17.98, 18.0], 'SGD', SHIPPED)[0], 'SGD uses .98'
    assert_equal 39.9, pick(39.7, [39.5, 39.7, 39.9, 40.0], 'ILS', SHIPPED)[0], 'ILS uses .90'
    assert_equal 88.0, pick(88.4, [87.0, 88.0, 88.8, 89.0], 'CNY', SHIPPED)[0], 'CNY likes an 8'
    assert_equal 349.0, pick(359.7, [345.0, 349.0, 350.0, 359.0, 360.0], 'INR', SHIPPED)[0], 'INR uses 49 and 99'
    assert_equal 19_000.0, pick(19_100, [18_900, 19_000, 19_100, 19_200], 'KRW', SHIPPED)[0], 'KRW prefers round thousands'
    assert_equal 9.9, pick(9.8, [9.5, 9.8, 9.9, 10.0], 'CHF', SHIPPED)[0], 'CHF uses .90'
  end

  # ---- second review ----------------------------------------------------

  def test_an_untouched_skipped_row_survives_a_rebuild_of_another_row
    inputs = [input('BRA', 10.0, points(5), 'available' => false, 'current_point_id' => 'cur'),
              input('IND', 10.0, points(3, 6, 10), 'current' => 10.0)]
    rows = Pricing.build_proposal(inputs, 'gni_bands', DATA, OPTS)
    out = Pricing.apply_csv_edits(rows, edit_csv(rows, 'IND' => '3'), { 'BRA' => points(5, 9.5), 'IND' => points(3, 6, 10) }, OPTS)
    bra = out.find { |r| r['territory'] == 'BRA' }
    assert Pricing.skipped?(bra)
    assert_equal 'unavailable', bra['note']
    assert_equal 'cur', bra['price_point_id']
    refute Pricing.changed?(bra)
    assert_equal 3.0, out.find { |r| r['territory'] == 'IND' }['proposed']
  end

  def test_a_three_decimal_price_written_by_the_script_is_left_alone
    rows = Pricing.build_proposal([input('KWT', 1.099, points(1.099, 1.5), 'current' => 1.099),
                                   input('IND', 10.0, points(3, 6, 10), 'current' => 10.0)], 'equalization', DATA, OPTS)
    pts = { 'KWT' => points(1.099, 1.5, 999), 'IND' => points(3, 6, 10) }
    [edit_csv(rows, 'IND' => '3'), edit_csv(rows, 'IND' => '3', 'KWT' => '1,099')].each do |csv|
      kwt = Pricing.apply_csv_edits(rows, csv, pts, OPTS).find { |r| r['territory'] == 'KWT' }
      assert_equal 1.099, kwt['proposed']
      assert_equal 'equalization', kwt['ratio_source']
    end
  end

  def test_parse_price_resolves_three_digits_by_the_row
    assert_equal 1.099, Pricing.parse_price('1.099', near: 1.2)
    assert_equal 1099.0, Pricing.parse_price('1.099', near: 1300)
    assert_equal 1099.0, Pricing.parse_price('1.099')
    assert_equal 1.299, Pricing.parse_price('1,299', near: 1.3)
    assert_equal 9.9, Pricing.parse_price('9,90', near: 1000), 'two decimals are never ambiguous'
  end

  def test_a_free_point_is_never_chosen
    assert_equal 0.29, Pricing.nearest_point(0.09, points(0, 0.29, 0.39))['price']
    price, = pick(0.09, [0, 0.29, 0.39], 'USD')
    assert_equal 0.29, price
    row = Pricing.build_row(input('IND', 1.0, points(0), 'current_point_id' => 'keep'), 'ppp', DATA, OPTS)
    assert_equal 'no paid price points', row['note']
    assert_equal 'keep', row['price_point_id']
  end

  def test_the_base_ignores_a_free_point_too
    row = Pricing.build_row(input('USA', 0.29, points(0, 0.29)), 'gni_bands', DATA, OPTS)
    assert_equal 0.29, row['proposed']
  end

  def test_persisted_options_drop_the_transient_keys
    kept = Pricing.persisted_options(CHARM)
    Pricing::TRANSIENT_OPTIONS.each { |key| refute kept.key?(key), key }
    assert_equal 'charm', kept[:endings]
  end
end
