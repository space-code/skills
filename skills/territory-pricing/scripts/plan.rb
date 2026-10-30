#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds a Price Proposal from data the agent collected from App Store
# Connect. Reads and writes local files only; it never calls the API.
#
#   ruby plan.rb --input plan-input.json --out DIR --strategy gni_bands [--base USA]
#   ruby plan.rb --out DIR --rebuild        # re-read an edited DIR/proposal.csv
#
# Input: {"product": {"kind", "id", "name", "period"}, "base_territory": "USA", "territories": [
#   {"territory", "currency", "current", "current_point_id", "equalized",
#    "available" (default true), "points": [{"id", "price"}]}]}
# product.period (ONE_MONTH, ONE_YEAR, ..., LIFETIME) is only needed by ladder.rb.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'fileutils'
require 'json'
require 'csv'
require 'time'
require 'pricing'
require 'snapshots'

NEEDED = { 'big_mac' => %i[big_mac ppp], 'ppp' => %i[ppp], 'gni_bands' => %i[gni] }.freeze

opts = { strategy: 'gni_bands' }
overrides = {}
OptionParser.new do |o|
  o.on('--input FILE') { |v| opts[:input] = v }
  o.on('--out DIR') { |v| opts[:out] = v }
  o.on('--strategy S', Pricing::STRATEGIES) { |v| opts[:strategy] = v }
  o.on('--base TERRITORY') { |v| overrides[:base_territory] = v.upcase }
  o.on('--tiers FILE', 'JSON for --strategy tiered') { |v| opts[:tiers] = v }
  o.on('--clamp-min F', Float) { |v| overrides[:clamp_min] = v }
  o.on('--clamp-max F', Float) { |v| overrides[:clamp_max] = v }
  o.on('--flag-threshold F', Float) { |v| overrides[:flag_threshold] = v }
  o.on('--endings MODE', Pricing::ENDING_MODES, 'none (nearest price point) or charm (customary endings)') { |v| overrides[:endings] = v }
  o.on('--endings-tolerance F', Float, 'how far from the target a charm price may be, default 0.05') { |v| overrides[:endings_tolerance] = v }
  o.on('--endings-file FILE', 'ending rules per currency, default references/data/endings.json') { |v| opts[:endings_file] = v }
  o.on('--rebuild') { opts[:rebuild] = true }
end.parse!
abort 'usage: see header of plan.rb' unless opts[:out] && (opts[:input] || opts[:rebuild])

def load_snapshot(name)
  rows = CSV.read(File.join(Snapshots::DATA_DIR, Snapshots::FILES.fetch(name)), headers: true)
  [rows.map { |r| [r['iso_a3'], Float(r['value'])] }.to_h, { 'origin' => 'snapshot', 'as_of' => rows.map { |r| r['as_of'] }.max }]
end

def money(value, currency)
  value ? format('%.2f %s', value, currency) : 'n/a'
end

def print_summary(meta, rows)
  s = Pricing.summary(rows)
  puts "Price Proposal: #{meta['product']&.values_at('kind', 'id')&.join(' ')} | strategy #{meta['strategy']} | base #{meta['base_territory']}"
  (meta['data'] || {}).each { |k, v| puts "  data #{k}: #{v['origin']} (as of #{v['as_of']})" }
  puts "Territories #{s['territories']} | priced #{s['priced']} | changed #{s['changed']} | decreases #{s['decreases']} | increases #{s['increases']} | flagged #{s['flagged']} | skipped #{s['skipped']}"
  puts "Ratio sources: #{s['sources'].map { |k, v| "#{k} #{v}" }.join(', ')}"
  o = (meta['options'] || {}).map { |k, v| [k.to_s, v] }.to_h
  puts "Price endings: #{o['endings'] || 'none'}#{" (within #{(o['endings_tolerance'] * 100).round}% of the target)" if o['endings'] == 'charm'}"
  moved = rows.select { |r| r['change_pct'] && Pricing.changed?(r) }.sort_by { |r| r['change_pct'] }
  { 'Largest decreases' => moved.first(8).select { |r| r['change_pct'].negative? },
    'Largest increases' => moved.last(8).reverse.select { |r| r['change_pct'].positive? } }.each do |title, list|
    next if list.empty?

    puts "#{title}:"
    list.each { |r| puts format('  %-4s %-14s -> %-14s %+6.1f%%  %s', r['territory'], money(r['current'], r['currency']), money(r['proposed'], r['currency']), r['change_pct'] * 100, r['flag']) }
  end
  skipped = rows.select { |r| Pricing.skipped?(r) }
  puts "Skipped, current price kept: #{skipped.map { |r| "#{r['territory']} (#{r['note']})" }.join(', ')}" unless skipped.empty?
end

FileUtils.mkdir_p(opts[:out])
proposal_path = File.join(opts[:out], 'proposal.json')
csv_path = File.join(opts[:out], 'proposal.csv')

if opts[:rebuild]
  proposal = JSON.parse(File.read(proposal_path))
  # same settings as the original run, unless the command line says otherwise
  stored = (proposal['meta']['options'] || {}).map { |k, v| [k.to_sym, v] }.to_h
  popts = Pricing.options(stored.merge(overrides).merge(base_territory: proposal['meta']['base_territory']))
  begin
    proposal['rows'] = Pricing.apply_csv_edits(proposal['rows'], File.read(csv_path), proposal['points'], popts)
  rescue Pricing::EditError => e
    warn "ERROR: #{e.message}; nothing was changed. Fix these cells and run --rebuild again:"
    e.problems.each { |line| warn "  #{line}" }
    exit 2
  end
  proposal['meta']['options'] = Pricing.persisted_options(popts)
  File.write(proposal_path, JSON.pretty_generate(proposal))
  File.write(csv_path, Pricing.to_csv(proposal['rows']))
  print_summary(proposal['meta'], proposal['rows'])
  exit 0
end

input = JSON.parse(File.read(opts[:input]))
base = overrides[:base_territory] || input['base_territory'] || 'USA'
endings_file = opts[:endings_file] || File.join(Snapshots::DATA_DIR, 'endings.json')
overrides[:endings_rules] = JSON.parse(File.read(endings_file))['currencies']
popts = Pricing.options(overrides.merge(base_territory: base))
inputs = input['territories'].map do |t|
  t.merge('available' => t.fetch('available', true),
          # a price in effect may sit on a legacy point Apple no longer lists
          'current_point_id' => Pricing.resolve_point_id(t['current_point_id'], t['current'], t['points'] || []))
end
abort "ERROR: base territory #{base} is missing from the input" unless inputs.any? { |t| t['territory'] == base }

data = { band1_overrides: JSON.parse(File.read(File.join(Snapshots::DATA_DIR, 'gni-bands.json')))['band1_overrides'] }
provenance = {}
(NEEDED[opts[:strategy]] || []).each { |name| data[name], provenance[name.to_s] = load_snapshot(name) }
if opts[:strategy] == 'tiered'
  abort 'ERROR: --strategy tiered needs --tiers FILE' unless opts[:tiers]

  cfg = JSON.parse(File.read(opts[:tiers]))
  data[:tiers] = (cfg['territories'] || {}).map { |t, tier| [t, Integer(tier)] }.to_h
  # tiers missing from the file keep their default ratio
  tier_ratios = Pricing::DEFAULT_OPTIONS[:tier_ratios].merge((cfg['tier_ratios'] || {}).map { |k, v| [Integer(k), Float(v)] }.to_h)
  popts = popts.merge(tier_ratios: tier_ratios)
  popts = popts.merge(default_tier: Integer(cfg['default_tier'])) if cfg['default_tier']
  unknown = (data[:tiers].values + [popts[:default_tier]]).uniq - tier_ratios.keys
  abort "ERROR: no ratio for tier #{unknown.join(', ')}; add it to tier_ratios in #{opts[:tiers]}" unless unknown.empty?
end

rows = Pricing.build_proposal(inputs, opts[:strategy], data, popts)
meta = { 'product' => input['product'], 'strategy' => opts[:strategy], 'base_territory' => base,
         'created_at' => Time.now.utc.iso8601, 'data' => provenance,
         'options' => Pricing.persisted_options(popts) }
points = inputs.map { |t| [t['territory'], t['points'] || []] }.to_h
File.write(proposal_path, JSON.pretty_generate('meta' => meta, 'rows' => rows, 'points' => points))
File.write(csv_path, Pricing.to_csv(rows))
print_summary(meta, rows)
puts "Files: #{proposal_path}, #{csv_path}"
