# frozen_string_literal: true

require 'date'
require 'pricing'

# Builds the body of POST /v1/appPriceSchedules and
# POST /v1/inAppPurchasePriceSchedules from a Price Proposal. Pure logic.
#
# Without a start date every territory gets one manual price that takes effect
# at once. With a start date a territory whose price changes keeps its current
# point until that day and switches on it; unchanged territories keep one
# immediate price. Shapes follow Apple's documented examples; the dated form is
# not verified against the live API.
module Schedule
  KINDS = {
    'app' => { type: 'appPriceSchedules', rel: 'app', rel_type: 'apps', price_type: 'appPrices',
               point_rel: 'appPricePoint', point_type: 'appPricePoints' },
    'iap' => { type: 'inAppPurchasePriceSchedules', rel: 'inAppPurchase', rel_type: 'inAppPurchases',
               price_type: 'inAppPurchasePrices', point_rel: 'inAppPurchasePricePoint',
               point_type: 'inAppPurchasePricePoints' }
  }.freeze

  module_function

  # rows: proposal rows; those without a price_point_id are left out of the schedule.
  def body(kind:, product_id:, base:, rows:, start_date: nil, today: Date.today)
    cfg = KINDS.fetch(kind) { raise ArgumentError, "unknown kind #{kind.inspect}" }
    validate_start_date!(start_date, today)
    prices = rows.select { |r| r['price_point_id'] }.flat_map { |row| entries(kind, row, start_date) }
    included = prices.each_with_index.map { |e, i| resource(kind, cfg, product_id, "${price#{i}}", e) }
    { 'data' => { 'type' => cfg[:type], 'attributes' => {},
                  'relationships' => { cfg[:rel] => reference(cfg[:rel_type], product_id),
                                       'baseTerritory' => reference('territories', base),
                                       'manualPrices' => { 'data' => included.map { |i| { 'type' => cfg[:price_type], 'id' => i['id'] } } } } },
      'included' => included }
  end

  def validate_start_date!(start_date, today)
    return unless start_date

    ok = Date.strptime(start_date, '%Y-%m-%d') > today
    raise ArgumentError, "start date must be after #{today}" unless ok
  rescue ArgumentError => e
    raise ArgumentError, e.message.start_with?('start date') ? e.message : "start date #{start_date.inspect} is not YYYY-MM-DD"
  end

  # [{point, start, end}] for one proposal row
  def entries(kind, row, start_date)
    new_point = row['price_point_id']
    return [{ point: new_point, start: nil, end: nil }] unless start_date && Pricing.changed?(row)
    return [{ point: new_point, start: start_date, end: nil }] unless row['current_point_id']

    [{ point: row['current_point_id'], start: nil, end: kind == 'app' ? start_date : nil },
     { point: new_point, start: start_date, end: nil }]
  end

  def resource(kind, cfg, product_id, id, entry)
    attributes = { 'startDate' => entry[:start] }
    attributes['endDate'] = entry[:end] if kind == 'app'
    relationships = { cfg[:point_rel] => reference(cfg[:point_type], entry[:point]) }
    relationships['inAppPurchaseV2'] = reference('inAppPurchases', product_id) if kind == 'iap'
    { 'type' => cfg[:price_type], 'id' => id, 'attributes' => attributes, 'relationships' => relationships }
  end

  def reference(type, id)
    { 'data' => { 'type' => type, 'id' => id } }
  end
end
