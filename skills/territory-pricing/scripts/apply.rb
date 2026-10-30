#!/usr/bin/env ruby
# frozen_string_literal: true

# Applies a Price Proposal to App Store Connect. DRY RUN unless --confirm.
#
#   ruby apply.rb --proposal DIR/proposal.json                       # dry run
#   ruby apply.rb --proposal DIR/proposal.json --confirm             # app / iap
#   ruby apply.rb --proposal DIR/proposal.json --confirm --phase canary   # subscription: 1-2 territories
#   ruby apply.rb --proposal DIR/proposal.json --confirm --phase rest     # subscription: the rest
#   ruby apply.rb --rollback DIR/before.json --confirm               # back to the snapshot
#
# Every write is followed by a read-back from App Store Connect; only what the
# read-back confirms is reported as applied.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'json'
require 'date'
require 'products'

opts = { phase: nil, canary: 2, preserve: true, confirm: false }
OptionParser.new do |o|
  o.on('--proposal FILE') { |v| opts[:proposal] = v }
  o.on('--rollback FILE', 'before.json snapshot to restore') { |v| opts[:rollback] = v }
  o.on('--confirm', 'actually write to App Store Connect') { opts[:confirm] = true }
  o.on('--phase PHASE', %w[all canary rest]) { |v| opts[:phase] = v }
  o.on('--canary N', Integer) { |v| opts[:canary] = v }
  o.on('--start-date DATE', 'subscriptions: YYYY-MM-DD, default tomorrow') { |v| opts[:start] = v }
  o.on('--no-preserve', 'subscriptions: do NOT keep current subscribers on their price') { opts[:preserve] = false }
end.parse!
abort 'usage: see header of apply.rb' unless opts[:proposal] || opts[:rollback]

def die(msg)
  abort "ERROR: #{msg}"
end

def money(value, currency)
  value ? format('%.2f %s', value, currency) : 'n/a'
end

def load_source(opts)
  unless opts[:rollback]
    doc = JSON.parse(File.read(opts[:proposal]))
    return [doc['meta'], doc['rows'], File.dirname(opts[:proposal])]
  end

  snap = JSON.parse(File.read(opts[:rollback]))
  rows = snap['prices'].select { |_, p| p['point_id'] }.map do |t, p|
    { 'territory' => t, 'price_point_id' => p['point_id'], 'proposed' => p['price'], 'currency' => p['currency'],
      'current_point_id' => nil, 'current' => nil, 'change_pct' => nil }
  end
  [{ 'kind' => snap['kind'], 'id' => snap['id'], 'base_territory' => snap['base_territory'] || 'USA' }, rows, File.dirname(opts[:rollback])]
end

def future_date?(str, today)
  Date.parse(str) > Date.parse(today)
rescue ArgumentError
  false
end

def read_log(path)
  File.file?(path) ? JSON.parse(File.read(path)) : { 'applied' => {}, 'failed' => {} }
end

def verify(product, rows, run_dir, start_date)
  after = product.snapshot
  File.write(File.join(run_dir, 'after.json'), JSON.pretty_generate(after))
  bad = rows.reject do |r|
    p = after['prices'][r['territory']] || {}
    p['point_id'] == r['price_point_id'] ||
      (start_date && (p['scheduled'] || []).any? { |s| s['start_date'] == start_date && s['point_id'] == r['price_point_id'] })
  end
  report = { 'checked' => rows.size, 'ok' => rows.size - bad.size,
             'mismatches' => bad.map { |r| { 'territory' => r['territory'], 'expected' => r['proposed'], 'point_id' => r['price_point_id'] } } }
  File.write(File.join(run_dir, 'verify.json'), JSON.pretty_generate(report))
  report
end

begin
  meta, rows, run_dir = load_source(opts)
  kind = meta['kind']
  product = Products.build(kind, meta['id'])
  base = meta['base_territory']
  subscription = kind == 'subscription'
  opts[:phase] ||= subscription ? 'canary' : 'all'
  die 'subscriptions must go through --phase canary, then --phase rest' if subscription && opts[:phase] == 'all'
  die "--phase #{opts[:phase]} is for subscriptions only" if !subscription && opts[:phase] != 'all'

  today = Products.today
  start = opts[:start] || (Date.parse(today) + 1).to_s
  die "--start-date must be a date after #{today}" if subscription && !future_date?(start, today)

  cancel = []
  if opts[:rollback]
    live = product.snapshot
    # only cancel changes that were not already scheduled when the snapshot was taken
    known = JSON.parse(File.read(opts[:rollback]))['prices'].values.flat_map { |p| (p['scheduled'] || []).map { |s| s['price_id'] } }
    live['prices'].each do |t, p|
      (p['scheduled'] || []).reject { |s| known.include?(s['price_id']) }.each { |s| cancel << [t, s] } if subscription
      rows.each { |r| r['current_point_id'] = p['point_id'] if r['territory'] == t }
    end
  end

  todo = rows.select { |r| Pricing.changed?(r) }
  submit = rows.select { |r| r['price_point_id'] }
  puts "#{opts[:confirm] ? 'APPLY' : 'DRY RUN'}: #{kind} #{meta['id']} (#{opts[:rollback] ? 'rollback' : meta['strategy']}), base #{base}"
  puts "  #{todo.size} of #{rows.size} territories differ from the current price"
  puts "  will cancel #{cancel.size} scheduled subscription price change(s) first" unless cancel.empty?
  if todo.empty? && cancel.empty?
    puts 'Nothing to do.'
    exit 0
  end

  if subscription
    log_path = File.join(run_dir, 'apply-log.json')
    log = read_log(log_path)
    pending = todo.reject { |r| log['applied'].key?(r['territory']) }
    canary = pending.reject { |r| r['territory'] == base }.first(opts[:canary])
    canary = pending.first(opts[:canary]) if canary.empty?
    if opts[:phase] == 'canary'
      batch = canary
    else
      die 'run --phase canary first and check its read-back' if log['applied'].empty?
      batch = pending
    end
    puts "  phase #{opts[:phase]}: #{batch.size} POST /v1/subscriptionPrices, startDate #{start}, preserveCurrentPrice #{opts[:preserve]}"
    batch.first(opts[:confirm] ? 0 : 8).each do |r|
      puts format('    %-4s %-14s -> %-14s', r['territory'], money(r['current'], r['currency']), money(r['proposed'], r['currency']))
    end
    puts '    ...' if !opts[:confirm] && batch.size > 8
    unless opts[:confirm]
      puts 'Dry run only. Nothing was written. Re-run with --confirm after the user agrees.'
      exit 0
    end

    cancel.each { |_, s| product.cancel_scheduled!(s['price_id']) }
    puts "  cancelled #{cancel.size} scheduled price change(s)" unless cancel.empty?
    if batch.empty?
      puts 'No price writes needed: the prices in effect already match.'
      exit 0
    end
    batch.each do |r|
      product.apply_one!(r, start, opts[:preserve])
      log['applied'][r['territory']] = { 'point_id' => r['price_point_id'], 'start_date' => start, 'at' => Time.now.utc.iso8601 }
      log['failed'].delete(r['territory'])
      puts "  wrote #{r['territory']}"
    rescue Asc::HttpError => e
      log['failed'][r['territory']] = e.message
      warn "  FAILED #{r['territory']}: #{e.message}"
      break if opts[:phase] == 'canary'
    ensure
      File.write(log_path, JSON.pretty_generate(log))
    end
    # the final report covers everything applied so far, canary included
    checked = (opts[:phase] == 'rest' ? todo : batch).select { |r| log['applied'].key?(r['territory']) }
  else
    puts "  1 POST creating a new price schedule: base #{base}, #{submit.size} manual prices (territories left out follow Apple's automatic prices)"
    unless opts[:confirm]
      puts 'Dry run only. Nothing was written. Re-run with --confirm after the user agrees.'
      exit 0
    end
    product.apply_all!(submit, base)
    puts '  schedule created'
    checked = submit
  end

  report = verify(product, checked, run_dir, subscription ? start : nil)
  puts "Read-back: #{report['ok']}/#{report['checked']} territories match what was sent"
  report['mismatches'].first(20).each { |m| puts "  MISMATCH #{m['territory']}: expected #{m['expected']}" }
  failed = subscription ? log['failed'] : {}
  failed.each { |t, msg| puts "  FAILED #{t}: #{msg}" }
  puts 'Subscriptions: new prices start on the start date; App Store Connect keeps showing the old price until then (scheduled change, not a failure).' if subscription
  puts 'Next: run --phase rest after the user reviews this read-back.' if subscription && opts[:phase] == 'canary'
  exit(report['mismatches'].empty? && failed.empty? ? 0 : 1)
rescue Asc::Error => e
  abort "ERROR: #{e.message}"
end
