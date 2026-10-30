# frozen_string_literal: true

require_relative 'test_helper'
require 'products'

# Canned App Store Connect responses (shapes follow Apple's documentation);
# Asc.paginate / Asc.request are stubbed, so nothing touches the network.
class ProductsTest < Minitest::Test
  def setup
    @original = { request: Asc.method(:request), paginate: Asc.method(:paginate) }
    @calls = []
    calls = @calls
    @responses = {}
    responses = @responses
    stub = lambda do |_name, target, body = nil|
      calls << [target, body]
      key = responses.keys.find { |k| target.include?(k) } or raise "unstubbed request: #{target}"
      responses[key]
    end
    Asc.singleton_class.send(:define_method, :request) { |method, target, body = nil| stub.call(method, target, body) }
    Asc.singleton_class.send(:define_method, :paginate) { |target| stub.call(:get, target) }
  end

  def teardown
    @original.each { |name, method| Asc.singleton_class.send(:define_method, name, method) }
  end

  def territory(id, currency)
    { 'type' => 'territories', 'id' => id, 'attributes' => { 'currency' => currency } }
  end

  def test_subscription_snapshot_splits_current_and_scheduled
    @responses['/v1/subscriptions/42/prices'] = {
      'data' => [
        { 'type' => 'subscriptionPrices', 'id' => 'p1', 'attributes' => { 'startDate' => nil },
          'relationships' => { 'territory' => { 'data' => { 'id' => 'BRA' } },
                               'subscriptionPricePoint' => { 'data' => { 'type' => 'subscriptionPricePoints', 'id' => 'old' } } } },
        { 'type' => 'subscriptionPrices', 'id' => 'p2', 'attributes' => { 'startDate' => '2099-01-01' },
          'relationships' => { 'territory' => { 'data' => { 'id' => 'BRA' } },
                               'subscriptionPricePoint' => { 'data' => { 'type' => 'subscriptionPricePoints', 'id' => 'new' } } } }
      ],
      'included' => [
        { 'type' => 'subscriptionPricePoints', 'id' => 'old', 'attributes' => { 'customerPrice' => '59.90' } },
        { 'type' => 'subscriptionPricePoints', 'id' => 'new', 'attributes' => { 'customerPrice' => '34.90' } },
        territory('BRA', 'BRL')
      ]
    }
    snap = Products.build('subscription', '42').snapshot('2026-10-30')
    bra = snap['prices']['BRA']
    assert_equal 'old', bra['point_id']
    assert_equal 59.9, bra['price']
    assert_equal 'BRL', bra['currency']
    assert_equal ['new'], bra['scheduled'].map { |s| s['point_id'] }
    assert_equal 'p2', bra['scheduled'].first['price_id']
  end

  def test_equalized_and_price_points_are_parsed
    @responses['/equalizations'] = {
      'data' => [{ 'id' => 'e1', 'attributes' => { 'customerPrice' => '34.90' },
                   'relationships' => { 'territory' => { 'data' => { 'id' => 'BRA' } } } }],
      'included' => [territory('BRA', 'BRL')]
    }
    @responses['/pricePoints'] = { 'data' => [{ 'id' => 'a', 'attributes' => { 'customerPrice' => '1.99' } },
                                               { 'id' => 'b', 'attributes' => { 'customerPrice' => 'oops' } }] }
    sub = Products.build('subscription', '42')
    assert_equal({ 'BRA' => { 'price' => 34.9, 'currency' => 'BRL' } }, sub.equalized('base'))
    assert_equal [{ 'id' => 'a', 'price' => 1.99 }], sub.price_points('BRA')
    assert(@calls.any? { |t, _| t.include?('filter%5Bterritory%5D=BRA') })
  end

  def test_subscription_price_request_shape
    @responses['/v1/subscriptionPrices'] = { 'data' => {} }
    Products.build('subscription', '42').apply_one!({ 'price_point_id' => 'pp9' }, '2026-11-01', true)
    target, body = @calls.last
    assert_equal '/v1/subscriptionPrices', target
    assert_equal({ 'startDate' => '2026-11-01', 'preserveCurrentPrice' => true }, body['data']['attributes'])
    assert_equal 'pp9', body['data']['relationships']['subscriptionPricePoint']['data']['id']
    assert_equal '42', body['data']['relationships']['subscription']['data']['id']
  end

  def test_app_schedule_is_one_request_with_base_and_all_manual_prices
    @responses['/v1/appPriceSchedules'] = { 'data' => {} }
    rows = [{ 'price_point_id' => 'usa-pp' }, { 'price_point_id' => 'bra-pp' }]
    Products.build('app', '7').apply_all!(rows, 'USA')
    target, body = @calls.last
    assert_equal '/v1/appPriceSchedules', target
    assert_equal 'USA', body['data']['relationships']['baseTerritory']['data']['id']
    assert_equal 2, body['data']['relationships']['manualPrices']['data'].size
    assert_equal %w[usa-pp bra-pp], body['included'].map { |i| i['relationships']['appPricePoint']['data']['id'] }
    assert_equal(body['included'].map { |i| i['id'] }, body['data']['relationships']['manualPrices']['data'].map { |i| i['id'] })
  end

  def test_iap_schedule_uses_iap_resource_types
    @responses['/v1/inAppPurchasePriceSchedules'] = { 'data' => {} }
    Products.build('iap', '8').apply_all!([{ 'price_point_id' => 'x' }], 'USA')
    _, body = @calls.last
    assert_equal 'inAppPurchases', body['data']['relationships']['inAppPurchase']['data']['type']
    assert_equal 'inAppPurchasePrices', body['included'].first['type']
  end

  def test_unreadable_availability_means_unknown_not_empty
    Asc.singleton_class.send(:define_method, :request) { |*| raise Asc::HttpError.new(404, '{}') }
    assert_nil Products.build('subscription', '42').available_territories
  end
end
