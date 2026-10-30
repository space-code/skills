#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the price ladder across the Price Proposals of one app: per territory a
# longer subscription is pricier but cheaper per month, and a lifetime unlock
# costs at least N times the cheapest yearly cost. Local files only.
#
#   ruby ladder.rb RUN_A/proposal.json RUN_B/proposal.json ... [--lifetime-min-years 2]
#
# Each proposal needs meta.product.period: the subscription period (ONE_MONTH,
# ONE_YEAR, ...) or LIFETIME for a lifetime unlock.
# Exit: 0 clean, 1 violations (also written to ladder.json next to the first
# proposal), 2 a proposal cannot be read or has no period.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'json'
require 'ladder'

min_years = 2.0

def fail_with(message)
  warn "ERROR: #{message}"
  exit 2
end

OptionParser.new do |o|
  o.on('--lifetime-min-years F', Float, 'lifetime must cost at least F x the yearly price, default 2') { |v| min_years = v }
end.parse!
fail_with 'usage: ruby ladder.rb PROPOSAL.json PROPOSAL.json ... [--lifetime-min-years F]' if ARGV.size < 2

products = ARGV.map do |path|
  proposal = JSON.parse(File.read(path))
  product = proposal.dig('meta', 'product') || {}
  period = product['period']
  fail_with "#{path} has no meta.product.period; put \"period\" in the product of plan-input.json" unless period

  rows = proposal['rows'].select { |r| r['proposed'] }
  { 'name' => product['name'] || File.basename(File.dirname(path)), 'period' => period,
    'prices' => rows.map { |r| [r['territory'], r['proposed']] }.to_h,
    'currencies' => rows.map { |r| [r['territory'], r['currency']] }.to_h }
rescue Errno::ENOENT, JSON::ParserError => e
  fail_with "cannot read #{path} (#{e.class})"
end

begin
  result = Ladder.check(products, min_lifetime_years: min_years)
rescue ArgumentError => e
  fail_with e.message
end
File.write(File.join(File.dirname(ARGV.first), 'ladder.json'),
           JSON.pretty_generate(result.merge('min_lifetime_years' => min_years, 'products' => products.map { |p| p.values_at('name', 'period') })))

puts "Ladder: #{products.map { |p| "#{p['name']} (#{p['period']})" }.join(', ')}"
puts "Checked #{result['checked']} territories, skipped #{result['skipped']} priced in only one product; lifetime must cost at least #{min_years}x yearly"
if result['violations'].empty?
  puts 'No violations.'
  exit 0
end
puts "#{result['violations'].size} violation(s):"
result['violations'].each { |v| puts format('  %-4s %-4s %-36s %s', v['territory'], v['currency'], v['rule'], v['detail']) }
exit 1
