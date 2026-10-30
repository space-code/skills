# frozen_string_literal: true

require 'csv'

# Pure pricing logic: no network, no file IO. Rows and entries use string keys
# so they round-trip through JSON untouched; options use symbol keys.
module Pricing
  STRATEGIES = %w[equalization gni_bands big_mac ppp tiered].freeze

  DEFAULT_OPTIONS = {
    base_territory: 'USA',
    clamp_min: 0.30,
    clamp_max: 1.30,
    flag_threshold: 0.25,
    band1_min_gni: 14_000.0,
    band2_min_gni: 4_500.0,
    band_ratios: { 1 => 1.0, 2 => 0.6, 3 => 0.3 },
    tier_ratios: { 1 => 1.0, 2 => 0.7, 3 => 0.4 },
    default_tier: 1
  }.freeze

  CSV_COLUMNS = %w[
    territory currency current equalized strategy ratio_source ratio clamped
    target proposed change_pct flag note price_point_id current_point_id
  ].freeze

  # fallback chain per strategy; everything ends in plain equalization (1.0)
  CHAINS = {
    'big_mac' => %w[big_mac ppp],
    'ppp' => %w[ppp],
    'gni_bands' => %w[gni_bands],
    'tiered' => %w[tiered]
  }.freeze

  module_function

  def options(overrides = {})
    DEFAULT_OPTIONS.merge(overrides)
  end

  # -> [ratio, source]; ratio multiplies the equalized local price.
  def ratio_for(strategy, territory, data, opts)
    CHAINS.fetch(strategy, []).each do |name|
      ratio = send("#{name}_ratio", territory, data, opts)
      return [ratio, name] if ratio
    end
    [1.0, 'equalization']
  end

  # Dollar price of a Big Mac relative to the base territory's.
  def big_mac_ratio(territory, data, opts)
    relative(data[:big_mac], territory, opts)
  end

  # PPP price level (PPP factor / market exchange rate), relative to the base.
  def ppp_ratio(territory, data, opts)
    relative(data[:ppp], territory, opts)
  end

  def relative(values, territory, opts)
    values ||= {}
    base = values[opts[:base_territory]]
    value = values[territory]
    return nil unless base && value && base.positive? && value.positive?

    value / base
  end

  def gni_bands_ratio(territory, data, opts)
    return opts[:band_ratios][1] if (data[:band1_overrides] || []).include?(territory)

    gni = (data[:gni] || {})[territory]
    return nil unless gni

    band = if gni >= opts[:band1_min_gni] then 1
           elsif gni >= opts[:band2_min_gni] then 2
           else 3
           end
    opts[:band_ratios][band]
  end

  def tiered_ratio(territory, data, opts)
    tier = (data[:tiers] || {}).fetch(territory, opts[:default_tier])
    opts[:tier_ratios][tier]
  end

  def clamp_ratio(ratio, opts)
    [[ratio, opts[:clamp_min]].max, opts[:clamp_max]].min
  end

  # Nearest price point; on a tie the cheaper one wins.
  def nearest_point(target, points)
    points.min_by { |p| [(p['price'] - target).abs, p['price']] }
  end

  # entries: {'territory','point_id','price','start_date','end_date',...}
  # -> [price in effect today or nil, scheduled future changes]
  def split_entries(entries, today)
    live = entries.select do |e|
      (e['start_date'].nil? || e['start_date'] <= today) && (e['end_date'].nil? || e['end_date'] > today)
    end
    scheduled = entries.select { |e| e['start_date'] && e['start_date'] > today }
    [live.max_by { |e| e['start_date'] || '' }, scheduled.sort_by { |e| e['start_date'] }]
  end

  # input: {'territory','currency','current','current_point_id','equalized','available','points'}
  def build_row(input, strategy, data, opts)
    row = {
      'territory' => input['territory'], 'currency' => input['currency'],
      'current' => input['current'], 'current_point_id' => input['current_point_id'],
      'equalized' => input['equalized'], 'strategy' => strategy,
      'ratio_source' => nil, 'ratio' => nil, 'clamped' => false, 'target' => nil,
      'price_point_id' => nil, 'proposed' => nil, 'change_pct' => nil, 'flag' => '', 'note' => ''
    }
    return skip(row, 'unavailable') unless input['available']
    return skip(row, 'no equalized price') unless input['equalized']
    return skip(row, 'no price points') if (input['points'] || []).empty?

    ratio, source = if input['territory'] == opts[:base_territory]
                      [1.0, 'base']
                    else
                      ratio_for(strategy, input['territory'], data, opts)
                    end
    applied = clamp_ratio(ratio, opts)
    target = input['equalized'] * applied
    point = nearest_point(target, input['points'])
    row.merge!('ratio_source' => source, 'ratio' => applied.round(4), 'clamped' => applied != ratio,
               'target' => target.round(2), 'price_point_id' => point['id'], 'proposed' => point['price'])
    finish(row, opts)
  end

  def skip(row, note)
    row.merge('note' => note)
  end

  def finish(row, opts)
    cur = row['current']
    row['change_pct'] = cur&.positive? ? ((row['proposed'] - cur) / cur).round(4) : nil
    flags = []
    flags << 'clamped' if row['clamped']
    flags << 'large-change' if row['change_pct'] && row['change_pct'].abs > opts[:flag_threshold]
    row['flag'] = flags.join(',')
    row
  end

  def build_proposal(inputs, strategy, data, opts)
    inputs.map { |i| build_row(i, strategy, data, opts) }
  end

  def changed?(row)
    !row['price_point_id'].nil? && row['price_point_id'] != row['current_point_id']
  end

  def summary(rows)
    priced = rows.select { |r| r['proposed'] }
    changed = rows.select { |r| changed?(r) }
    {
      'territories' => rows.size,
      'priced' => priced.size,
      'changed' => changed.size,
      'decreases' => changed.count { |r| r['change_pct'] && r['change_pct'] < 0 },
      'increases' => changed.count { |r| r['change_pct'] && r['change_pct'] > 0 },
      'flagged' => rows.count { |r| !r['flag'].to_s.empty? },
      'skipped' => rows.count { |r| r['proposed'].nil? },
      'sources' => priced.each_with_object(Hash.new(0)) { |r, h| h[r['ratio_source']] += 1 }
    }
  end

  def to_csv(rows)
    CSV.generate do |csv|
      csv << CSV_COLUMNS
      rows.each { |r| csv << CSV_COLUMNS.map { |c| r[c] } }
    end
  end

  # Re-snaps hand-edited `proposed` values of a proposal.csv onto real price
  # points. An emptied `proposed` cell means "leave this territory alone".
  # points_by_territory: {'BRA' => [{'id','price'}, ...]}
  def apply_csv_edits(rows, csv_text, points_by_territory, opts)
    edited = CSV.parse(csv_text, headers: true).each_with_object({}) { |r, h| h[r['territory']] = r['proposed'] }
    rows.map do |row|
      next row unless edited.key?(row['territory'])

      raw = edited[row['territory']].to_s.strip
      if raw.empty?
        next row['proposed'].nil? ? row : row.merge('price_point_id' => row['current_point_id'],
                                                    'proposed' => row['current'], 'flag' => '', 'note' => 'left unchanged by user')
      end
      value = Float(raw)
      next row if row['proposed'] && (value - row['proposed']).abs < 0.005

      point = nearest_point(value, points_by_territory.fetch(row['territory'], []))
      next row.merge('note' => 'no price points for manual edit') unless point

      finish(row.merge('price_point_id' => point['id'], 'proposed' => point['price'], 'ratio_source' => 'manual',
                       'note' => 'edited by user'), opts)
    end
  end
end
