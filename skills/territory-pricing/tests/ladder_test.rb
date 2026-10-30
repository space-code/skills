# frozen_string_literal: true

require_relative 'test_helper'
require 'ladder'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class LadderTest < Minitest::Test
  LADDER = File.expand_path('../scripts/ladder.rb', __dir__)

  def product(name, period, prices)
    { 'name' => name, 'period' => period, 'prices' => prices, 'currencies' => prices.keys.map { |t| [t, 'USD'] }.to_h }
  end

  def clean
    [product('monthly', 'ONE_MONTH', 'USA' => 4.99, 'BRA' => 14.9),
     product('yearly', 'ONE_YEAR', 'USA' => 39.99, 'BRA' => 119.9),
     product('lifetime', 'LIFETIME', 'USA' => 99.99, 'BRA' => 299.0)]
  end

  def rules(result)
    result['violations'].map { |v| [v['territory'], v['rule']] }
  end

  def test_a_clean_ladder_has_no_violations
    result = Ladder.check(clean)
    assert_empty result['violations']
    assert_equal 2, result['checked']
  end

  def test_yearly_above_lifetime_is_caught
    products = clean
    products[1]['prices']['BRA'] = 400.0
    assert_includes rules(Ladder.check(products)), %w[BRA lifetime_too_cheap]
  end

  def test_lifetime_must_be_at_least_two_yearly_by_default
    products = clean
    products[2]['prices']['USA'] = 59.99 # above yearly, below 2x yearly
    assert_equal [%w[USA lifetime_too_cheap]], rules(Ladder.check(products))
  end

  def test_the_lifetime_threshold_is_configurable
    products = clean
    products[2]['prices']['USA'] = 59.99
    assert_empty Ladder.check(products, min_lifetime_years: 1.0)['violations']
  end

  def test_yearly_below_monthly_is_caught_as_not_pricier
    products = clean
    products[1]['prices']['USA'] = 3.99
    assert_includes rules(Ladder.check(products)), %w[USA longer_period_not_pricier]
  end

  def test_yearly_dearer_than_twelve_months_is_caught
    products = clean
    products[1]['prices']['USA'] = 61.0 # 12 x 4.99 = 59.88
    assert_equal [%w[USA longer_period_costs_more_per_month]], rules(Ladder.check(products, min_lifetime_years: 1.0))
  end

  def test_yearly_exactly_twelve_months_is_allowed
    products = clean
    products[1]['prices']['USA'] = 59.88
    assert_empty Ladder.check(products, min_lifetime_years: 1.0)['violations']
  end

  def test_a_weekly_plan_is_normalised_to_a_month
    products = [product('weekly', 'ONE_WEEK', 'USA' => 1.99), product('monthly', 'ONE_MONTH', 'USA' => 4.99)]
    assert_empty Ladder.check(products)['violations'], '4.99 a month is cheaper per month than 1.99 a week'
    products[1]['prices']['USA'] = 9.99 # 4.33 weeks x 1.99 = 8.62 a month
    assert_equal [%w[USA longer_period_costs_more_per_month]], rules(Ladder.check(products))
  end

  def test_three_and_six_month_plans_are_ordered_by_length
    products = [product('3m', 'THREE_MONTHS', 'USA' => 12.99), product('6m', 'SIX_MONTHS', 'USA' => 20.99),
                product('1m', 'ONE_MONTH', 'USA' => 4.99)]
    assert_empty Ladder.check(products)['violations']
  end

  def test_territories_priced_in_one_product_only_are_skipped
    products = clean
    products[2]['prices'].delete('BRA')
    products[1]['prices'].delete('BRA')
    result = Ladder.check(products)
    assert_equal 1, result['checked']
    assert_equal 1, result['skipped']
  end

  def test_lifetime_only_has_nothing_to_compare_with
    assert_equal 0, Ladder.check([product('lifetime', 'LIFETIME', 'USA' => 99.0)])['checked']
  end

  def test_violations_carry_the_currency
    products = clean
    products[2]['prices']['USA'] = 10.0
    assert_equal 'USD', Ladder.check(products)['violations'].first['currency']
  end

  def test_an_unknown_period_is_rejected
    assert_raises(ArgumentError) { Ladder.check([product('x', 'FORTNIGHT', 'USA' => 1.0), product('y', 'ONE_MONTH', 'USA' => 2.0)]) }
  end

  # ---- the command line ----------------------------------------------------

  def write_proposal(dir, name, period, prices)
    path = File.join(dir, name)
    FileUtils.mkdir_p(path)
    rows = prices.map { |t, p| { 'territory' => t, 'currency' => 'USD', 'proposed' => p } }
    meta = { 'product' => { 'name' => name, 'period' => period }.compact }
    File.write(File.join(path, 'proposal.json'), JSON.generate('meta' => meta, 'rows' => rows))
    File.join(path, 'proposal.json')
  end

  def run_ladder(*args)
    Open3.capture3(RbConfig.ruby, LADDER, *args)
  end

  def test_cli_exits_zero_when_the_ladder_is_clean
    Dir.mktmpdir do |dir|
      files = [write_proposal(dir, 'monthly', 'ONE_MONTH', 'USA' => 4.99), write_proposal(dir, 'yearly', 'ONE_YEAR', 'USA' => 39.99),
               write_proposal(dir, 'lifetime', 'LIFETIME', 'USA' => 99.99)]
      out, err, status = run_ladder(*files)
      assert status.success?, err
      assert_includes out, 'No violations.'
    end
  end

  def test_cli_exits_one_and_names_the_territory_on_a_violation
    Dir.mktmpdir do |dir|
      files = [write_proposal(dir, 'yearly', 'ONE_YEAR', 'USA' => 39.99, 'BRA' => 200.0),
               write_proposal(dir, 'lifetime', 'LIFETIME', 'USA' => 99.99, 'BRA' => 150.0)]
      out, _, status = run_ladder(*files)
      assert_equal 1, status.exitstatus
      assert_includes out, 'BRA'
      assert_includes out, 'lifetime_too_cheap'
      saved = JSON.parse(File.read(File.join(dir, 'yearly', 'ladder.json')))
      assert_equal 1, saved['violations'].size
    end
  end

  def test_cli_threshold_flag
    Dir.mktmpdir do |dir|
      files = [write_proposal(dir, 'yearly', 'ONE_YEAR', 'USA' => 39.99), write_proposal(dir, 'lifetime', 'LIFETIME', 'USA' => 60.0)]
      assert_equal 1, run_ladder(*files).last.exitstatus
      assert_equal 0, run_ladder(*files, '--lifetime-min-years', '1').last.exitstatus
    end
  end

  def test_cli_names_a_proposal_without_a_period
    Dir.mktmpdir do |dir|
      files = [write_proposal(dir, 'yearly', 'ONE_YEAR', 'USA' => 39.99), write_proposal(dir, 'lifetime', nil, 'USA' => 99.0)]
      _, err, status = run_ladder(*files)
      assert_equal 2, status.exitstatus
      assert_includes err, 'lifetime/proposal.json'
      assert_includes err, 'period'
    end
  end

  def test_cli_needs_two_proposals
    assert_equal 2, run_ladder('only-one.json').last.exitstatus
  end

  def test_two_plans_of_one_period_are_both_compared_with_the_longer_one
    a = product('monthly A', 'ONE_MONTH', 'USA' => 10.0)
    b = product('monthly B', 'ONE_MONTH', 'USA' => 5.0)
    y = product('yearly', 'ONE_YEAR', 'USA' => 70.0) # 5.83 a month, dearer than B
    [[a, b, y], [b, a, y], [y, b, a]].each do |order|
      found = Ladder.check(order, min_lifetime_years: 1.0)['violations']
      assert(found.any? { |v| v['rule'] == 'longer_period_costs_more_per_month' && v['detail'].include?('monthly B') },
             order.map { |p| p['name'] }.join(', '))
    end
  end
end
