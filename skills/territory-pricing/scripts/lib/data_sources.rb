# frozen_string_literal: true

require 'csv'
require 'json'
require 'net/http'
require 'uri'
require 'time'

# Economic inputs for the pricing strategies. Live fetch first, bundled
# snapshot (references/data/) when the network or the source fails.
module DataSources
  DATA_DIR = File.expand_path('../../references/data', __dir__)
  BIG_MAC_URL = 'https://raw.githubusercontent.com/TheEconomist/big-mac-data/master/output-data/big-mac-full-index.csv'
  WORLD_BANK = 'https://api.worldbank.org/v2'
  BIG_MAC_MAX_AGE_YEARS = 3
  WB_YEARS = '2019:2026'
  EUROZONE = %w[AUT BEL BGR HRV CYP EST FIN FRA DEU GRC IRL ITA LVA LTU LUX MLT NLD PRT SVK SVN ESP].freeze

  module_function

  # -> [{ big_mac:, ppp:, gni:, band1_overrides: }, provenance]
  def load(needed, offline: false)
    data = { band1_overrides: band1_overrides }
    provenance = {}
    needed.each do |name|
      values, meta = offline ? [nil, nil] : try_live(name)
      values, meta = snapshot(name) unless values
      data[name] = values
      provenance[name.to_s] = meta
    end
    [data, provenance]
  end

  def needed_for(strategy)
    { 'big_mac' => %i[big_mac ppp], 'ppp' => %i[ppp], 'gni_bands' => %i[gni] }.fetch(strategy, [])
  end

  def try_live(name)
    send("fetch_#{name}")
  rescue StandardError => e
    warn "warn: live #{name} fetch failed (#{e.class}: #{e.message}); using bundled snapshot"
    nil
  end

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
    countries = JSON.parse(get("#{WORLD_BANK}/country?format=json&per_page=400"))[1]
                    .reject { |c| c['region']['id'] == 'NA' }.map { |c| c['id'] }
    rows = JSON.parse(get("#{WORLD_BANK}/country/all/indicator/#{indicator}?format=json&per_page=20000&date=#{WB_YEARS}"))[1] || []
    rows.each_with_object({}) do |r, h|
      next unless r['value'] && countries.include?(r['countryiso3code'])

      (h[r['countryiso3code']] ||= {})[r['date'].to_i] = r['value'].to_f
    end
  end

  # ---- bundled snapshot ---------------------------------------------------

  def snapshot(name)
    file = { big_mac: 'big-mac.csv', ppp: 'ppp.csv', gni: 'gni.csv' }.fetch(name)
    path = File.join(DATA_DIR, file)
    return [nil, { 'origin' => 'missing', 'as_of' => nil }] unless File.file?(path)

    rows = CSV.read(path, headers: true)
    values = rows.each_with_object({}) { |r, h| h[r['iso_a3']] = Float(r['value']) }
    [values, { 'origin' => 'snapshot', 'as_of' => rows.map { |r| r['as_of'] }.max, 'source' => "references/data/#{file}" }]
  end

  def band1_overrides
    path = File.join(DATA_DIR, 'gni-bands.json')
    File.file?(path) ? JSON.parse(File.read(path))['band1_overrides'] : []
  end

  def write_snapshot(name, values, as_of)
    file = { big_mac: 'big-mac.csv', ppp: 'ppp.csv', gni: 'gni.csv' }.fetch(name)
    File.write(File.join(DATA_DIR, file), CSV.generate do |csv|
      csv << %w[iso_a3 value as_of]
      values.sort.each { |iso, v| csv << [iso, v.round(6), as_of] }
    end)
  end
end
