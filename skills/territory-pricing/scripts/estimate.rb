#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds a Price Proposal. Read-only: it never writes to App Store Connect.
#   ruby estimate.rb --kind subscription --id 6447497832 --strategy gni_bands --out DIR
#   ruby estimate.rb --out DIR --rebuild      # re-read proposal.csv after hand edits
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'fileutils'
require 'json'
require 'products'
require 'data_sources'

opts = { strategy: 'gni_bands' }
overrides = {}
OptionParser.new do |o|
  o.on('--kind KIND', Products::KINDS) { |v| opts[:kind] = v }
  o.on('--id ID') { |v| opts[:id] = v }
  o.on('--strategy S', Pricing::STRATEGIES) { |v| opts[:strategy] = v }
  o.on('--base TERRITORY', 'base territory, default: the schedule base or USA') { |v| overrides[:base_territory] = v.upcase }
  o.on('--out DIR') { |v| opts[:out] = v }
  o.on('--tiers FILE', 'JSON for --strategy tiered') { |v| opts[:tiers] = v }
  o.on('--clamp-min F', Float) { |v| overrides[:clamp_min] = v }
  o.on('--clamp-max F', Float) { |v| overrides[:clamp_max] = v }
  o.on('--flag-threshold F', Float) { |v| overrides[:flag_threshold] = v }
  o.on('--offline', 'use bundled data snapshots only') { opts[:offline] = true }
  o.on('--rebuild', 'rebuild proposal.json from an edited proposal.csv') { opts[:rebuild] = true }
end.parse!
abort 'usage: see header of estimate.rb' unless opts[:out]

def money(value, currency)
  value ? format('%.2f %s', value, currency) : 'n/a'
end

def print_summary(meta, rows)
  s = Pricing.summary(rows)
  puts "Price Proposal: #{meta['kind']} #{meta['id']} | strategy #{meta['strategy']} | base #{meta['base_territory']}"
  (meta['data'] || {}).each { |k, v| puts "  data #{k}: #{v['origin']} (as of #{v['as_of']})" }
  puts "Territories #{s['territories']} | priced #{s['priced']} | changed #{s['changed']} | decreases #{s['decreases']} | increases #{s['increases']} | flagged #{s['flagged']} | skipped #{s['skipped']}"
  puts "Ratio sources: #{s['sources'].map { |k, v| "#{k} #{v}" }.join(', ')}"
  moved = rows.select { |r| r['change_pct'] && Pricing.changed?(r) }.sort_by { |r| r['change_pct'] }
  { 'Largest decreases' => moved.first(8), 'Largest increases' => moved.last(8).reverse.select { |r| r['change_pct'].positive? } }.each do |title, list|
    next if list.empty?

    puts "#{title}:"
    list.each { |r| puts format('  %-4s %-14s -> %-14s %+6.1f%%  %s', r['territory'], money(r['current'], r['currency']), money(r['proposed'], r['currency']), r['change_pct'] * 100, r['flag']) }
  end
  skipped = rows.select { |r| r['proposed'].nil? }
  puts "Skipped: #{skipped.map { |r| "#{r['territory']} (#{r['note']})" }.join(', ')}" unless skipped.empty?
end

begin
  FileUtils.mkdir_p(opts[:out])
  proposal_path = File.join(opts[:out], 'proposal.json')
  points_path = File.join(opts[:out], 'price_points.json')

  if opts[:rebuild]
    proposal = JSON.parse(File.read(proposal_path))
    popts = Pricing.options(overrides.merge(base_territory: proposal['meta']['base_territory']))
    proposal['rows'] = Pricing.apply_csv_edits(proposal['rows'], File.read(File.join(opts[:out], 'proposal.csv')),
                                               JSON.parse(File.read(points_path)), popts)
    File.write(proposal_path, JSON.pretty_generate(proposal))
    File.write(File.join(opts[:out], 'proposal.csv'), Pricing.to_csv(proposal['rows']))
    print_summary(proposal['meta'], proposal['rows'])
    exit 0
  end

  abort 'usage: see header of estimate.rb' unless opts[:kind] && opts[:id]
  product = Products.build(opts[:kind], opts[:id])

  warn 'reading current prices...'
  snap = product.snapshot
  File.write(File.join(opts[:out], 'before.json'), JSON.pretty_generate(snap))
  base = overrides[:base_territory] || snap['base_territory'] || 'USA'
  popts = Pricing.options(overrides.merge(base_territory: base))
  base_entry = snap['prices'][base]
  abort "ERROR: no price in effect in base territory #{base}; pick another with --base" unless base_entry && base_entry['point_id']

  # The price in effect may sit on a legacy price point that Apple no longer
  # lists; equalizations only accept a listed one, so resolve it by price.
  points = { base => product.price_points(base) }
  base_point_id = Pricing.resolve_point_id(base_entry['point_id'], base_entry['price'], points[base])
  abort "ERROR: the #{base} price #{base_entry['price']} matches no current price point; pick another with --base" unless points[base].any? { |p| p['id'] == base_point_id }

  warn "reading equalized prices from #{base}..."
  equalized = product.equalized(base_point_id)
  equalized[base] ||= { 'price' => base_entry['price'], 'currency' => base_entry['currency'] }
  availability = product.available_territories

  territories = equalized.keys.sort
  territories.each_with_index do |t, i|
    next if points.key?(t)

    warn format('reading price points [%<i>d/%<n>d] %<t>s', i: i + 1, n: territories.size, t: t)
    points[t] = product.price_points(t)
  end
  File.write(points_path, JSON.pretty_generate(points))

  data, provenance = DataSources.load(DataSources.needed_for(opts[:strategy]), offline: opts[:offline])
  if opts[:strategy] == 'tiered'
    abort 'ERROR: --strategy tiered needs --tiers FILE' unless opts[:tiers]

    cfg = JSON.parse(File.read(opts[:tiers]))
    data[:tiers] = (cfg['territories'] || {}).map { |t, tier| [t, Integer(tier)] }.to_h
    tier_ratios = (cfg['tier_ratios'] || {}).map { |k, v| [Integer(k), Float(v)] }.to_h
    popts = popts.merge(tier_ratios: tier_ratios) unless tier_ratios.empty?
    popts = popts.merge(default_tier: Integer(cfg['default_tier'])) if cfg['default_tier']
  end
  missing = DataSources.needed_for(opts[:strategy]).select { |n| data[n].nil? }
  abort "ERROR: no #{missing.join(', ')} data (live fetch failed and no bundled snapshot)" unless missing.empty?

  inputs = territories.map do |t|
    cur = snap['prices'][t] || {}
    { 'territory' => t, 'currency' => equalized[t]['currency'] || cur['currency'], 'current' => cur['price'],
      'current_point_id' => Pricing.resolve_point_id(cur['point_id'], cur['price'], points[t]),
      'equalized' => equalized[t]['price'],
      'available' => availability.nil? || availability.include?(t), 'points' => points[t] }
  end
  rows = Pricing.build_proposal(inputs, opts[:strategy], data, popts)

  meta = { 'kind' => opts[:kind], 'id' => opts[:id], 'strategy' => opts[:strategy], 'base_territory' => base,
           'created_at' => Time.now.utc.iso8601, 'data' => provenance,
           'options' => popts.reject { |k, _| %i[band_ratios tier_ratios].include?(k) } }
  File.write(proposal_path, JSON.pretty_generate('meta' => meta, 'rows' => rows))
  File.write(File.join(opts[:out], 'proposal.csv'), Pricing.to_csv(rows))
  print_summary(meta, rows)
  scheduled = snap['prices'].count { |_, p| !p['scheduled'].empty? }
  puts "WARNING: #{scheduled} territories already have a scheduled price change." if scheduled.positive?
  puts "Files: #{opts[:out]}/{before.json,proposal.json,proposal.csv,price_points.json}"
rescue Asc::Error => e
  abort "ERROR: #{e.message}"
end
