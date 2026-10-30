# frozen_string_literal: true

require 'time'
require 'asc'
require 'pricing'

# One adapter per product kind. Each answers the same questions (current
# prices, price points, equalized prices) and knows how to write prices back.
module Products
  KINDS = %w[app iap subscription].freeze

  module_function

  def build(kind, id)
    { 'app' => App, 'iap' => Iap, 'subscription' => Subscription }.fetch(kind) { raise Asc::Error, "unknown kind #{kind}" }.new(id)
  end

  def today
    Time.now.utc.strftime('%Y-%m-%d')
  end

  # Products the user can price for one app: the app itself, its IAPs and
  # every auto-renewable subscription, grouped by subscription group.
  def list(app_id)
    items = [{ 'kind' => 'app', 'id' => app_id, 'name' => 'App price (paid app)' }]
    Asc.paginate(Asc.path("/v1/apps/#{app_id}/inAppPurchasesV2", 'limit' => 200))['data'].each do |d|
      items << { 'kind' => 'iap', 'id' => d['id'], 'name' => d.dig('attributes', 'name'),
                 'detail' => d.dig('attributes', 'inAppPurchaseType') }
    end
    Asc.paginate(Asc.path("/v1/apps/#{app_id}/subscriptionGroups", 'limit' => 200))['data'].each do |g|
      Asc.paginate(Asc.path("/v1/subscriptionGroups/#{g['id']}/subscriptions", 'limit' => 200))['data'].each do |s|
        items << { 'kind' => 'subscription', 'id' => s['id'], 'name' => s.dig('attributes', 'name'),
                   'group' => g.dig('attributes', 'referenceName'), 'detail' => s.dig('attributes', 'subscriptionPeriod') }
      end
    end
    items
  end

  class Base
    attr_reader :id

    def initialize(id)
      @id = id
    end

    # {'territory' => {'point_id','price','currency','start_date','scheduled' => [...]}}
    def snapshot(today = Products.today)
      prices = current_entries.group_by { |e| e['territory'] }.each_with_object({}) do |(territory, entries), out|
        current, scheduled = Pricing.split_entries(entries, today)
        out[territory] = (current || {}).reject { |k, _| k == 'end_date' }.merge('scheduled' => scheduled)
      end
      { 'kind' => kind, 'id' => id, 'fetched_at' => Time.now.utc.iso8601, 'base_territory' => base_territory, 'prices' => prices }
    end

    # All price points of one territory: [{'id','price'}]
    def price_points(territory)
      points_from(Asc.paginate(Asc.path(price_points_path, 'filter[territory]' => territory, 'limit' => 200)))
    end

    # Equalized price points of a base point, one per territory:
    # {'BRA' => {'price' => 59.9, 'currency' => 'BRL'}}
    def equalized(point_id)
      resp = Asc.paginate(Asc.path(equalizations_path(point_id), 'include' => 'territory', 'limit' => 200))
      inc = Asc.index_included(resp['included'])
      resp['data'].each_with_object({}) do |d, h|
        territory = territory_of(d)
        price = price_of(d)
        next unless territory && price

        h[territory] = { 'price' => price, 'currency' => inc[['territories', territory]]&.dig('attributes', 'currency') }
      end
    end

    # Territories the product is for sale in, or nil when Apple's answer
    # could not be read (callers then treat every territory as available).
    def available_territories
      fetch_available
    rescue Asc::HttpError => e
      warn "warn: could not read territory availability (#{e.message}); treating all territories as available"
      nil
    end

    private

    def price_of(resource)
      v = resource.dig('attributes', 'customerPrice') || resource.dig('attributes', 'equalizationPrice')
      v && Float(v, exception: false)
    end

    def territory_of(resource)
      resource.dig('relationships', 'territory', 'data', 'id')
    end

    def points_from(resp)
      resp['data'].map { |d| { 'id' => d['id'], 'price' => price_of(d) } }.select { |p| p['price'] }
    end

    # price resources (appPrices / inAppPurchasePrices / subscriptionPrices)
    # joined with their price point and territory
    def entries_from(resp, point_rel)
      inc = Asc.index_included(resp['included'])
      resp['data'].map do |p|
        ref = p.dig('relationships', point_rel, 'data')
        point = ref && inc[[ref['type'], ref['id']]]
        territory = territory_of(p) || (point && territory_of(point))
        {
          'territory' => territory, 'point_id' => ref && ref['id'], 'price' => point && price_of(point),
          'currency' => inc[['territories', territory]]&.dig('attributes', 'currency'),
          'start_date' => p.dig('attributes', 'startDate'), 'end_date' => p.dig('attributes', 'endDate'),
          'price_id' => p['id']
        }
      end.select { |e| e['territory'] }
    end

    def reference(type, id)
      { 'data' => { 'type' => type, 'id' => id } }
    end
  end

  class App < Base
    def kind
      'app'
    end

    def schedule_id
      @schedule_id ||= Asc.request(:get, "/v1/apps/#{id}/appPriceSchedule")['data']['id']
    end

    def base_territory
      Asc.request(:get, "/v1/appPriceSchedules/#{schedule_id}/baseTerritory")['data']['id']
    end

    def current_entries
      %w[manualPrices automaticPrices].flat_map do |rel|
        resp = Asc.paginate(Asc.path("/v1/appPriceSchedules/#{schedule_id}/#{rel}",
                                     'include' => 'appPricePoint,territory', 'limit' => 200))
        entries_from(resp, 'appPricePoint')
      end
    end

    # One schedule with the base territory and every manual price. Posting
    # the base alone would wipe the per-territory prices, so never do that.
    def apply_all!(rows, base)
      body = schedule_body('appPriceSchedules', 'app', 'apps', 'appPrices', 'appPricePoint', 'appPricePoints', rows, base)
      Asc.request(:post, '/v1/appPriceSchedules', body)
    end

    private

    def price_points_path

      "/v1/apps/#{id}/appPricePoints"

    end

    def equalizations_path(point_id)

      "/v3/appPricePoints/#{point_id}/equalizations"

    end

    def fetch_available
      av = Asc.request(:get, "/v1/apps/#{id}/appAvailabilityV2")['data']['id']
      resp = Asc.paginate(Asc.path("/v2/appAvailabilities/#{av}/territoryAvailabilities", 'limit' => 200))
      resp['data'].select { |d| d.dig('attributes', 'available') }.map { |d| territory_of(d) }.compact
    end

    def schedule_body(type, rel, rel_type, price_type, point_rel, point_type, rows, base)
      included = rows.each_with_index.map do |row, i|
        { 'type' => price_type, 'id' => "${price#{i}}", 'attributes' => { 'startDate' => nil },
          'relationships' => { point_rel => reference(point_type, row['price_point_id']) } }
      end
      { 'data' => { 'type' => type, 'attributes' => {},
                    'relationships' => { rel => reference(rel_type, id), 'baseTerritory' => reference('territories', base),
                                         'manualPrices' => { 'data' => included.map { |i| { 'type' => price_type, 'id' => i['id'] } } } } },
        'included' => included }
    end
  end

  class Iap < App
    def kind
      'iap'
    end

    def schedule_id
      @schedule_id ||= Asc.request(:get, "/v2/inAppPurchases/#{id}/iapPriceSchedule")['data']['id']
    end

    def base_territory
      Asc.request(:get, "/v1/inAppPurchasePriceSchedules/#{schedule_id}/baseTerritory")['data']['id']
    end

    def current_entries
      %w[manualPrices automaticPrices].flat_map do |rel|
        resp = Asc.paginate(Asc.path("/v1/inAppPurchasePriceSchedules/#{schedule_id}/#{rel}",
                                     'include' => 'inAppPurchasePricePoint,territory', 'limit' => 200))
        entries_from(resp, 'inAppPurchasePricePoint')
      end
    end

    def apply_all!(rows, base)
      body = schedule_body('inAppPurchasePriceSchedules', 'inAppPurchase', 'inAppPurchases', 'inAppPurchasePrices',
                           'inAppPurchasePricePoint', 'inAppPurchasePricePoints', rows, base)
      Asc.request(:post, '/v1/inAppPurchasePriceSchedules', body)
    end

    private

    def price_points_path

      "/v2/inAppPurchases/#{id}/pricePoints"

    end

    def equalizations_path(point_id)

      "/v1/inAppPurchasePricePoints/#{point_id}/equalizations"

    end

    def fetch_available
      av = Asc.request(:get, "/v2/inAppPurchases/#{id}/inAppPurchaseAvailability")['data']['id']
      resp = Asc.paginate(Asc.path("/v1/inAppPurchaseAvailabilities/#{av}/availableTerritories", 'limit' => 200))
      resp['data'].map { |d| d['id'] }
    end
  end

  class Subscription < Base
    def kind
      'subscription'
    end

    # Subscriptions have no base territory in the API; the caller picks one.
    def base_territory
      nil
    end

    def current_entries
      resp = Asc.paginate(Asc.path("/v1/subscriptions/#{id}/prices", 'include' => 'subscriptionPricePoint,territory', 'limit' => 200))
      entries_from(resp, 'subscriptionPricePoint')
    end

    # One call per territory; Apple has no bulk endpoint.
    def apply_one!(row, start_date, preserve)
      body = { 'data' => { 'type' => 'subscriptionPrices',
                           'attributes' => { 'startDate' => start_date, 'preserveCurrentPrice' => preserve },
                           'relationships' => { 'subscription' => reference('subscriptions', id),
                                                'subscriptionPricePoint' => reference('subscriptionPricePoints', row['price_point_id']) } } }
      Asc.request(:post, '/v1/subscriptionPrices', body)
    end

    def cancel_scheduled!(price_id)
      Asc.request(:delete, "/v1/subscriptionPrices/#{price_id}")
    end

    private

    def price_points_path

      "/v1/subscriptions/#{id}/pricePoints"

    end

    def equalizations_path(point_id)

      "/v1/subscriptionPricePoints/#{point_id}/equalizations"

    end

    def fetch_available
      av = Asc.request(:get, "/v1/subscriptions/#{id}/subscriptionAvailability?include=availableTerritories")
      (av.dig('data', 'relationships', 'availableTerritories', 'data') || []).map { |t| t['id'] }
    end
  end
end
