# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'csv'

# plan.rb end to end on a fixture; reads the bundled snapshots, never the network.
class PlanTest < Minitest::Test
  PLAN = File.expand_path('../scripts/plan.rb', __dir__)
  INPUT = File.expand_path('fixtures/plan_input.json', __dir__)
  TIERS = File.expand_path('fixtures/tiers.json', __dir__)

  def plan(dir, *args)
    out, err, status = Open3.capture3(RbConfig.ruby, PLAN, '--out', dir, *args)
    assert status.success?, "plan.rb failed: #{err}"
    out
  end

  def rows(dir)
    JSON.parse(File.read(File.join(dir, 'proposal.json')))['rows'].map { |r| [r['territory'], r] }.to_h
  end

  def test_tiered_proposal_snaps_to_listed_points
    Dir.mktmpdir do |dir|
      out = plan(dir, '--input', INPUT, '--strategy', 'tiered', '--tiers', TIERS)
      r = rows(dir)
      assert_equal 'bra-49', r['BRA']['price_point_id'], '79.9 x 0.6 = 47.9 -> 49.9'
      assert_equal 'ind-299', r['IND']['price_point_id'], '999 x 0.3 = 299.7 -> 299'
      assert_equal 'deu-12', r['DEU']['price_point_id']
      assert_includes out, 'Price Proposal: subscription 42'
    end
  end

  def test_legacy_current_point_does_not_count_as_a_change
    Dir.mktmpdir do |dir|
      plan(dir, '--input', INPUT, '--strategy', 'equalization')
      usa = rows(dir)['USA']
      assert_equal 'usa-11', usa['current_point_id'], 'legacy id is resolved by price'
      refute Pricing.changed?(usa)
    end
  end

  def test_base_keeps_its_price_and_unavailable_is_skipped
    Dir.mktmpdir do |dir|
      plan(dir, '--input', INPUT, '--strategy', 'tiered', '--tiers', TIERS)
      r = rows(dir)
      assert_equal 'base', r['USA']['ratio_source']
      assert_equal 11.99, r['USA']['proposed']
      assert_nil r['ZZZ']['proposed']
      assert_equal 'unavailable', r['ZZZ']['note']
    end
  end

  def test_gni_bands_use_the_bundled_snapshot
    Dir.mktmpdir do |dir|
      out = plan(dir, '--input', INPUT, '--strategy', 'gni_bands')
      r = rows(dir)
      assert_equal 'gni_bands', r['IND']['ratio_source']
      assert_equal 0.3, r['IND']['ratio']
      assert_includes out, 'data gni: snapshot'
    end
  end

  def test_edited_csv_is_rebuilt_onto_a_listed_point
    Dir.mktmpdir do |dir|
      plan(dir, '--input', INPUT, '--strategy', 'tiered', '--tiers', TIERS)
      csv_path = File.join(dir, 'proposal.csv')
      table = CSV.read(csv_path, headers: true)
      table.each { |row| row['proposed'] = '45' if row['territory'] == 'BRA' }
      File.write(csv_path, table.to_csv)
      plan(dir, '--rebuild')
      bra = rows(dir)['BRA']
      assert_equal 'bra-49', bra['price_point_id'], '45 snaps to 49.9'
      assert_equal 'manual', bra['ratio_source']
    end
  end

  def test_input_without_the_base_territory_is_rejected
    Dir.mktmpdir do |dir|
      _, err, status = Open3.capture3(RbConfig.ruby, PLAN, '--out', dir, '--input', INPUT, '--base', 'FRA', '--strategy', 'equalization')
      refute status.success?
      assert_includes err, 'FRA'
    end
  end

  def test_charm_endings_are_reported_and_saved
    Dir.mktmpdir do |dir|
      out = plan(dir, '--input', INPUT, '--strategy', 'tiered', '--tiers', TIERS, '--endings', 'charm')
      assert_includes out, 'Price endings: charm (within 5% of the target)'
      options = JSON.parse(File.read(File.join(dir, 'proposal.json')))['meta']['options']
      assert_equal 'charm', options['endings']
      refute options.key?('endings_rules'), 'the rules file is not copied into the proposal'
    end
  end

  def test_endings_default_to_nearest
    Dir.mktmpdir do |dir|
      assert_includes plan(dir, '--input', INPUT, '--strategy', 'equalization'), 'Price endings: none'
    end
  end

  def test_unknown_ending_mode_is_rejected
    Dir.mktmpdir do |dir|
      _, err, status = Open3.capture3(RbConfig.ruby, PLAN, '--out', dir, '--input', INPUT, '--endings', 'fancy')
      refute status.success?
      assert_includes err, 'fancy'
    end
  end
end

