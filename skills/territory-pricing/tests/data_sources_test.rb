# frozen_string_literal: true

require_relative 'test_helper'
require 'data_sources'

class DataSourcesTest < Minitest::Test
  def parsed
    DataSources.parse_big_mac(File.read(File.join(__dir__, 'fixtures', 'big_mac.csv')), 2026)
  end

  def test_big_mac_keeps_latest_fresh_rows_only
    values, as_of = parsed
    assert_equal '2026-07-01', as_of
    assert_in_delta 6.22, values['USA']
    refute values.key?('RUS'), 'stale rows are dropped'
    refute values.key?('BAD'), 'rows without a price are dropped'
  end

  def test_euro_area_row_is_spread_over_members
    values, = parsed
    assert_in_delta 7.07, values['DEU']
    assert_in_delta 7.07, values['FRA']
    refute values.key?('EUZ')
  end

  def test_needed_data_per_strategy
    assert_equal %i[big_mac ppp], DataSources.needed_for('big_mac')
    assert_equal %i[gni], DataSources.needed_for('gni_bands')
    assert_equal [], DataSources.needed_for('equalization')
  end

  def test_bundled_snapshots_load_offline
    data, provenance = DataSources.load(%i[big_mac ppp gni], offline: true)
    %i[big_mac ppp gni].each do |name|
      assert data[name].size > 50, "#{name} snapshot is too small"
      assert_equal 'snapshot', provenance[name.to_s]['origin']
    end
    assert_includes data[:band1_overrides], 'JPN'
  end
end
