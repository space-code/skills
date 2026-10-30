#!/usr/bin/env ruby
# frozen_string_literal: true

# Refreshes the bundled snapshots in references/data/ from the live sources
# (The Economist Big Mac index, World Bank indicators). plan.rb reads only the
# snapshots, so run this when the data should be newer.
#   ruby refresh_data.rb

require 'csv'
require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'set'
require_relative 'lib/snapshots'

module DataSources
  BIG_MAC_URL = 'https://raw.githubusercontent.com/TheEconomist/big-mac-data/master/output-data/big-mac-full-index.csv'
  WORLD_BANK = 'https://api.worldbank.org/v2'
  BIG_MAC_MAX_AGE_YEARS = 3
  WB_YEARS = '2019:2026'
  EUROZONE = %w[AUT BEL BGR HRV CYP EST FIN FRA DEU GRC IRL ITA LVA LTU LUX MLT NLD PRT SVK SVN ESP].freeze

  module_function

  def get(url, redirects = 3)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 40) { |h| h.get(uri.request_uri) }
    return get(res['location'], redirects - 1) if res.is_a?(Net::HTTPRedirection) && redirects.positive?
    raise "HTTP #{res.code} from #{uri.host}" unless res.is_a?(Net::HTTPSuccess)

    res.body
  end

  # ---- Big Mac index (The Economist) -------------------------------------

  def fetch_big_mac
    values, as_of = parse_big_mac(get(BIG_MAC_URL), Time.now.utc.year)
    raise 'empty Big Mac data' if values.empty?

    [values, { 'origin' => 'live', 'as_of' => as_of, 'source' => BIG_MAC_URL }]
  end

  # -> [{'BRA' => dollar_price}, as_of]; keeps each country's latest row,
  # drops stale ones, spreads the euro-area row over its members.
  def parse_big_mac(csv_text, this_year)
    latest = {}
    CSV.parse(csv_text, headers: true).each do |r|
      price = Float(r['dollar_price'], exception: false)
      next unless price && r['iso_a3'] && (latest[r['iso_a3']].nil? || r['date'] > latest[r['iso_a3']][:date])

      latest[r['iso_a3']] = { date: r['date'], price: price }
    end
    fresh = latest.select { |_, v| v[:date][0, 4].to_i >= this_year - BIG_MAC_MAX_AGE_YEARS }
    values = {}
    fresh.each { |iso, v| values[iso] = v[:price] }
    (fresh['EUZ'] ? EUROZONE : []).each { |iso| values[iso] ||= fresh['EUZ'][:price] }
    values.delete('EUZ')
    [values, fresh.values.map { |v| v[:date] }.max]
  end

  # ---- World Bank ---------------------------------------------------------

  def fetch_ppp
    levels = {}
    years = {}
    ppp = world_bank('PA.NUS.PRVT.PP')
    fx = world_bank('PA.NUS.FCRF')
    ppp.each do |iso, by_year|
      year = (by_year.keys & (fx[iso] || {}).keys).max
      next unless year && fx[iso][year].positive?

      levels[iso] = by_year[year] / fx[iso][year]
      years[iso] = year
    end
    raise 'empty PPP data' if levels.empty?

    [levels, { 'origin' => 'live', 'as_of' => years.values.max, 'source' => "#{WORLD_BANK} PA.NUS.PRVT.PP / PA.NUS.FCRF" }]
  end

  def fetch_gni
    values = {}
    years = {}
    world_bank('NY.GNP.PCAP.CD').each do |iso, by_year|
      year = by_year.keys.max
      values[iso] = by_year[year]
      years[iso] = year
    end
    raise 'empty GNI data' if values.empty?

    [values, { 'origin' => 'live', 'as_of' => years.values.max, 'source' => "#{WORLD_BANK} NY.GNP.PCAP.CD" }]
  end

  # -> {'BRA' => {2024 => value, ...}}, countries only (no aggregates)
  def world_bank(indicator)
    countries = country_codes
    rows = JSON.parse(get("#{WORLD_BANK}/country/all/indicator/#{indicator}?format=json&per_page=20000&date=#{WB_YEARS}"))[1] || []
    rows.each_with_object({}) do |r, h|
      next unless r['value'] && countries.include?(r['countryiso3code'])

      (h[r['countryiso3code']] ||= {})[r['date'].to_i] = r['value'].to_f
    end
  end

  # The country list is the same for every indicator: fetch it once.
  def country_codes
    @country_codes ||= JSON.parse(get("#{WORLD_BANK}/country?format=json&per_page=400"))[1]
                           .reject { |c| c['region']['id'] == 'NA' }.map { |c| c['id'] }.to_set
  end

  def write_snapshot(name, values, as_of)
    File.write(File.join(Snapshots::DATA_DIR, Snapshots::FILES.fetch(name)), CSV.generate do |csv|
      csv << %w[iso_a3 value as_of]
      values.sort.each { |iso, v| csv << [iso, v.round(6), as_of] }
    end)
  end
end

if $PROGRAM_NAME == __FILE__
  %i[big_mac ppp gni].each do |name|
    values, meta = DataSources.send("fetch_#{name}")
    DataSources.write_snapshot(name, values, meta['as_of'])
    puts "#{name}: #{values.size} countries, as of #{meta['as_of']}"
  rescue StandardError => e
    warn "#{name}: FAILED (#{e.class}: #{e.message}); snapshot left unchanged"
    exit 1
  end
end
