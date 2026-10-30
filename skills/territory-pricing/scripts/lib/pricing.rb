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
    default_tier: 1,
    endings: 'none',
    endings_tolerance: 0.05,
    endings_rules: {}
  }.freeze

  ENDING_MODES = %w[none charm].freeze
  # Cent-based currencies without a rule of their own like .99 and .49.
  DEFAULT_CENT_ENDINGS = [99, 49].freeze

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

  # Prices in effect can sit on legacy price points that Apple no longer
  # lists (and whose equalizations 404). Map such a point onto the listed
  # point with the same price; otherwise keep the id as is.
  def resolve_point_id(point_id, price, points)
    return point_id if point_id.nil? || points.any? { |p| p['id'] == point_id } || price.nil?

    match = points.min_by { |p| (p['price'] - price).abs }
    match && (match['price'] - price).abs < 0.005 ? match['id'] : point_id
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
    applied = source == 'base' ? ratio : clamp_ratio(ratio, opts)
    target = input['equalized'] * applied
    point, note = if source == 'base'
                    [nearest_point(target, input['points']), '']
                  else
                    pick_point(target, input['points'], input['currency'], opts)
                  end
    row.merge!('ratio_source' => source, 'ratio' => applied.round(4), 'clamped' => applied != ratio,
               'target' => target.round(2), 'price_point_id' => point['id'], 'proposed' => point['price'], 'note' => note)
    finish(row, opts)
  end

  # Nearest price point, or with endings 'charm' the nearest one whose ending
  # is customary in the currency, looked for within the tolerance around the
  # target. The clamp already bounded the ratio that produced the target, so
  # the window may reach slightly past it: a 3.49 for a 3.60 target is fine.
  # -> [point, note]
  def pick_point(target, points, currency, opts)
    nearest = nearest_point(target, points)
    return [nearest, ''] unless opts[:endings] == 'charm'

    tol = opts[:endings_tolerance]
    lo = target * (1 - tol)
    hi = target * (1 + tol)
    whole = points.none? { |p| (p['price'] % 1).abs > 1e-9 }
    nice = points.select { |p| p['price'].between?(lo, hi) && charm?(p['price'], currency, whole, opts) }
    return [nearest, "no charm ending within #{(tol * 100).round}%"] if nice.empty?

    [nice.min_by { |p| [(p['price'] - target).abs, p['price']] }, '']
  end

  # Is the price customary for the currency? A currency rule is
  # {'unit','mod','endings'}: (price * unit).round % mod must be one of the
  # endings. Without a rule: cent currencies use .99 / .49, whole-number
  # currencies use round numbers (at most two significant digits).
  def charm?(price, currency, whole, opts)
    rule = (opts[:endings_rules] || {})[currency]
    return rule['endings'].include?((price * rule['unit']).round % rule['mod']) if rule
    return round_number?(price) if whole

    DEFAULT_CENT_ENDINGS.include?((price * 100).round % 100)
  end

  def round_number?(price)
    return false unless price.positive?

    (price.round % (10**[Math.log10(price).floor - 1, 0].max)).zero?
  end

  # A skipped row is not repriced, and it keeps its current price point: an
  # app or in-app purchase schedule lists every manual price, so a row
  # without one would drop the territory back to Apple's automatic price.
  # ratio_source stays nil, which is what marks the row as skipped.
  def skip(row, note)
    row.merge('note' => note, 'price_point_id' => row['current_point_id'], 'proposed' => row['current'])
  end

  def skipped?(row)
    row['ratio_source'].nil?
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
    priced = rows.reject { |r| skipped?(r) }
    changed = rows.select { |r| changed?(r) }
    {
      'territories' => rows.size,
      'priced' => priced.size,
      'changed' => changed.size,
      'decreases' => changed.count { |r| r['change_pct'] && r['change_pct'] < 0 },
      'increases' => changed.count { |r| r['change_pct'] && r['change_pct'] > 0 },
      'flagged' => rows.count { |r| !r['flag'].to_s.empty? },
      'skipped' => rows.count { |r| skipped?(r) },
      'sources' => priced.each_with_object(Hash.new(0)) { |r, h| h[r['ratio_source']] += 1 }
    }
  end

  def to_csv(rows)
    CSV.generate do |csv|
      csv << CSV_COLUMNS
      rows.each { |r| csv << CSV_COLUMNS.map { |c| r[c] } }
    end
  end

  class EditError < StandardError
    attr_reader :problems

    def initialize(problems)
      @problems = problems
      super("#{problems.size} cell(s) in proposal.csv cannot be read as a price")
    end
  end

  # '9,90', '$4.99', '1,299.00', '1.299,00', '1 299' -> 1299.0 etc.; nil when
  # unreadable or not positive. The last separator is the decimal one, except
  # a lone separator with exactly three digits after it ('1,299'): thousands.
  def parse_price(raw)
    s = raw.to_s.gsub(/[^\d.,]/, '')
    return nil unless s =~ /\d/

    last = [s.rindex(','), s.rindex('.')].compact.max
    value = if last.nil?
              s
            elsif s[(last + 1)..-1].length == 3 && s.count(',.') == 1
              s.delete(',.')
            else
              "#{s[0...last].delete(',.')}.#{s[(last + 1)..-1]}"
            end
    price = Float(value, exception: false)
    price&.positive? ? price : nil
  end

  # Re-snaps hand-edited `proposed` values of a proposal.csv onto real price
  # points. An emptied `proposed` cell means "leave this territory alone".
  # Unreadable cells raise EditError before anything is changed.
  # points_by_territory: {'BRA' => [{'id','price'}, ...]}
  def apply_csv_edits(rows, csv_text, points_by_territory, opts)
    edited = CSV.parse(csv_text, headers: true).each_with_object({}) { |r, h| h[r['territory']] = r['proposed'].to_s.strip }
    problems = edited.reject { |_, raw| raw.empty? || parse_price(raw) }.map { |t, raw| "#{t}: '#{raw}'" }
    raise EditError, problems unless problems.empty?

    rows.map do |row|
      raw = edited[row['territory']]
      next row if raw.nil?
      next keep_current(row, opts) if raw.empty?

      value = parse_price(raw)
      next row if row['proposed'] && (value - row['proposed']).abs < 0.005 && !skipped?(row)

      point = nearest_point(value, points_by_territory.fetch(row['territory'], []))
      next row.merge('note' => 'no price points for manual edit') unless point

      finish(row.merge('price_point_id' => point['id'], 'proposed' => point['price'], 'ratio_source' => 'manual',
                       'clamped' => false, 'ratio' => nil, 'target' => value.round(2), 'note' => 'edited by user'), opts)
    end
  end

  def keep_current(row, opts)
    return row.merge('note' => 'no current price to keep') if row['current'].nil? || row['current_point_id'].nil?

    finish(row.merge('price_point_id' => row['current_point_id'], 'proposed' => row['current'], 'ratio_source' => 'unchanged',
                     'clamped' => false, 'ratio' => nil, 'target' => nil, 'note' => 'left unchanged by user'), opts)
  end
end
