# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require_relative '../scripts/refresh_data'

# refresh_data.rb with the network stubbed.
class RefreshDataTest < Minitest::Test
  COUNTRIES = JSON.generate([{}, [{ 'id' => 'BRA', 'region' => { 'id' => 'LCN' } }, { 'id' => 'WLD', 'region' => { 'id' => 'NA' } }]])
  INDICATOR = JSON.generate([{}, [{ 'countryiso3code' => 'BRA', 'date' => '2024', 'value' => 1.5 },
                                  { 'countryiso3code' => 'WLD', 'date' => '2024', 'value' => 9.9 }]])

  def setup
    @original = DataSources.method(:get)
    DataSources.instance_variable_set(:@country_codes, nil)
    @urls = []
    urls = @urls
    DataSources.singleton_class.send(:define_method, :get) do |url, *|
      urls << url
      url.include?('/country?') ? COUNTRIES : INDICATOR
    end
  end

  def teardown
    DataSources.singleton_class.send(:define_method, :get, @original)
    DataSources.instance_variable_set(:@country_codes, nil)
  end

  def test_the_country_list_is_fetched_once_for_all_indicators
    DataSources.world_bank('PA.NUS.PRVT.PP')
    DataSources.world_bank('PA.NUS.FCRF')
    DataSources.world_bank('NY.GNP.PCAP.CD')
    assert_equal 1, @urls.count { |u| u.include?('/country?') }
    assert_equal 3, @urls.count { |u| u.include?('/indicator/') }
  end

  def test_aggregates_are_dropped
    assert_equal({ 'BRA' => { 2024 => 1.5 } }, DataSources.world_bank('PA.NUS.PRVT.PP'))
  end

  def test_snapshot_paths_come_from_the_shared_module
    assert_equal Snapshots::DATA_DIR, File.expand_path('../references/data', __dir__)
    assert_equal %i[big_mac ppp gni], Snapshots::FILES.keys
  end

  def test_one_failed_source_does_not_stop_the_others
    written = []
    stubs = {
      fetch_big_mac: proc { raise 'HTTP 404 from raw.githubusercontent.com' },
      fetch_ppp: proc { [{ 'BRA' => 0.46 }, { 'as_of' => 2025 }] },
      fetch_gni: proc { [{ 'BRA' => 10_550.0 }, { 'as_of' => 2025 }] },
      write_snapshot: proc { |name, *| written << name }
    }
    originals = stubs.keys.map { |name| [name, DataSources.method(name)] }.to_h
    stubs.each { |name, impl| DataSources.singleton_class.send(:define_method, name, &impl) }
    out = StringIO.new
    assert_equal [:big_mac], DataSources.refresh_all(out)
    assert_equal %i[ppp gni], written
    assert_includes out.string, 'big_mac: FAILED'
  ensure
    originals.each { |name, method| DataSources.singleton_class.send(:define_method, name, method) }
  end
end
