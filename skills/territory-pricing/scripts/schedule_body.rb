#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds the request body that writes a Price Proposal of an app or an in-app
# purchase to App Store Connect. Local files only: it sends nothing.
#
#   ruby schedule_body.rb --proposal DIR/proposal.json --kind app|iap --id PRODUCT_ID \
#        [--start-date YYYY-MM-DD] > DIR/body.json
#   ruby asc.rb POST /v1/appPriceSchedules @DIR/body.json --write      (after the user agreed)
#
# Without --start-date the prices take effect at once. With it, changed
# territories switch on that day (use the start date of the subscriptions so
# the whole family changes together).
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'json'
require 'time'
require 'schedule'

opts = {}
OptionParser.new do |o|
  o.on('--proposal FILE') { |v| opts[:proposal] = v }
  o.on('--kind KIND', Schedule::KINDS.keys) { |v| opts[:kind] = v }
  o.on('--id ID') { |v| opts[:id] = v }
  o.on('--start-date DATE', 'YYYY-MM-DD, after today (UTC)') { |v| opts[:start] = v }
end.parse!
abort 'usage: see header of schedule_body.rb' unless opts.values_at(:proposal, :kind, :id).all?

proposal = JSON.parse(File.read(opts[:proposal]))
begin
  body = Schedule.body(kind: opts[:kind], product_id: opts[:id], base: proposal['meta']['base_territory'],
                       rows: proposal['rows'], start_date: opts[:start], today: Time.now.utc.to_date)
rescue ArgumentError => e
  abort "ERROR: #{e.message}"
end
dated = body['included'].count { |i| i['attributes']['startDate'] }
warn "#{body['included'].size} price entries for #{proposal['rows'].count { |r| r['price_point_id'] }} territories" \
     "#{", #{dated} starting on #{opts[:start]}" if opts[:start]}"
puts JSON.pretty_generate(body)
