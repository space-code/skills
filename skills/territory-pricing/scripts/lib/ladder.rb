# frozen_string_literal: true

# Price ladder across the products of one app, per territory: a longer
# subscription costs more in total but less per month, and a lifetime unlock
# costs at least `min_lifetime_years` times the cheapest yearly cost of the
# subscriptions. Pure logic: no network, no file IO.
module Ladder
  MONTHS = {
    'ONE_WEEK' => 12.0 / 52, 'ONE_MONTH' => 1.0, 'TWO_MONTHS' => 2.0,
    'THREE_MONTHS' => 3.0, 'SIX_MONTHS' => 6.0, 'ONE_YEAR' => 12.0
  }.freeze
  LIFETIME = 'LIFETIME'
  EPSILON = 1e-9

  module_function

  # products: [{'name', 'period', 'prices' => {'BRA' => 34.9}, 'currencies' => {'BRA' => 'BRL'}}]
  # -> {'violations' => [{'territory','currency','rule','detail'}], 'checked' => n, 'skipped' => n}
  # A territory priced in fewer than two products cannot be compared and is skipped.
  def check(products, min_lifetime_years: 2.0)
    unknown = products.reject { |p| MONTHS.key?(p['period']) || p['period'] == LIFETIME }
    raise ArgumentError, "unknown period #{unknown.first['period'].inspect} of #{unknown.first['name']}" unless unknown.empty?

    subs = products.select { |p| MONTHS.key?(p['period']) }.sort_by { |p| [MONTHS[p['period']], p['name'].to_s] }
    lifetimes = products.select { |p| p['period'] == LIFETIME }
    result = { 'violations' => [], 'checked' => 0, 'skipped' => 0 }
    products.flat_map { |p| p['prices'].keys }.uniq.sort.each do |territory|
      if products.count { |p| p['prices'][territory] } < 2
        result['skipped'] += 1
        next
      end
      result['checked'] += 1
      currency = products.map { |p| (p['currencies'] || {})[territory] }.compact.first
      found = compare_subscriptions(subs, territory) + compare_lifetime(subs, lifetimes, territory, min_lifetime_years)
      found.each { |rule, detail| result['violations'] << { 'territory' => territory, 'currency' => currency, 'rule' => rule, 'detail' => detail } }
    end
    result
  end

  # Every pair of subscriptions with different periods, not only neighbours:
  # with two monthly plans both must be compared with the yearly one.
  def compare_subscriptions(subs, territory)
    subs.select { |p| p['prices'][territory] }.combination(2).flat_map do |short, long|
      next [] if MONTHS[short['period']] == MONTHS[long['period']]

      s = short['prices'][territory]
      l = long['prices'][territory]
      found = []
      found << ['longer_period_not_pricier', "#{describe(long, l)} is not above #{describe(short, s)}"] if l <= s + EPSILON
      if l / MONTHS[long['period']] > s / MONTHS[short['period']] * (1 + EPSILON)
        found << ['longer_period_costs_more_per_month', "#{describe(long, l)} costs more per month than #{describe(short, s)}"]
      end
      found
    end
  end

  def compare_lifetime(subs, lifetimes, territory, min_years)
    priced = subs.select { |p| p['prices'][territory] }
    return [] if priced.empty?

    cheapest = priced.map { |p| [p['prices'][territory] * 12 / MONTHS[p['period']], p] }.min_by(&:first)
    lifetimes.select { |p| p['prices'][territory] }.flat_map do |life|
      price = life['prices'][territory]
      next [] unless price < cheapest[0] * min_years * (1 - EPSILON)

      [['lifetime_too_cheap', "#{describe(life, price)} is below #{min_years}x the yearly cost of #{cheapest[1]['name']} (#{format('%.2f', cheapest[0])})"]]
    end
  end

  def describe(product, price)
    "#{product['name']} #{format('%.2f', price)}"
  end
end
