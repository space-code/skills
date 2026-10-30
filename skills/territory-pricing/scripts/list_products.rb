#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only lookup of apps and their priceable products.
#   ruby list_products.rb --apps [--bundle-id com.acme.app]
#   ruby list_products.rb --app 6447402192
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'json'
require 'products'

opts = {}
OptionParser.new do |o|
  o.on('--apps') { opts[:apps] = true }
  o.on('--bundle-id ID') { |v| opts[:bundle_id] = v }
  o.on('--app ID') { |v| opts[:app] = v }
end.parse!
abort 'usage: ruby list_products.rb --apps [--bundle-id ID] | --app APP_ID' unless opts[:apps] || opts[:app]

begin
  if opts[:apps]
    params = { 'limit' => 200, 'fields[apps]' => 'name,bundleId' }
    params['filter[bundleId]'] = opts[:bundle_id] if opts[:bundle_id]
    Asc.paginate(Asc.path('/v1/apps', params))['data'].each do |a|
      puts format('%-12s %-40s %s', a['id'], a.dig('attributes', 'bundleId'), a.dig('attributes', 'name'))
    end
  else
    Products.list(opts[:app]).each do |p|
      puts format('%-13s %-12s %-28s %s', p['kind'], p['id'], p['name'], [p['group'], p['detail']].compact.join(' / '))
    end
  end
rescue Asc::Error => e
  abort "ERROR: #{e.message}"
end
