# Pricing strategies

Every strategy produces a **ratio** per territory. The target price is

```
target = equalized_local_price x ratio        (ratio clamped to [clamp_min, clamp_max], default 0.30 .. 1.30)
proposed = the nearest price point Apple offers in that territory (ties go to the cheaper one)
```

The ratio multiplies Apple's *already equalized local* price, so a 0.3 ratio lands at 30% of what Apple
would charge there, not 30% of the US price in dollars. The base territory always keeps its price.

## Fallback chain

When a territory has no data for the chosen strategy, the next source is used and the table's
`ratio_source` column says which one:

```
big_mac -> ppp -> equalization (ratio 1.0)
ppp -> equalization
gni_bands -> equalization
tiered -> default tier
```

## gni_bands (default)

Three bands on GNI per capita (World Bank Atlas method, `NY.GNP.PCAP.CD`):

| Band | GNI per capita | Ratio |
|---|---|---|
| 1 | >= 14,000 USD | 1.0 |
| 2 | 4,500 .. 14,000 USD | 0.6 |
| 3 | < 4,500 USD | 0.3 |

Band-1 overrides regardless of income (`references/data/gni-bands.json`): the Gulf states, Japan, South
Korea, Singapore, Hong Kong, Taiwan. Cut points and ratios are options (`band1_min_gni`, `band2_min_gni`,
`band_ratios`). Simple to explain and to defend; steps rather than a smooth curve.

## ppp

Price level of each country relative to the base: PPP conversion factor for private consumption divided by
the market exchange rate (`PA.NUS.PRVT.PP / PA.NUS.FCRF`, latest year both exist). Brazil is about 0.46,
Japan about 0.69, India about 0.23 (US = 1.0). Smooth and covers about 200 countries. Reflects what a basket of
goods costs, not willingness to pay for software, so the clamp matters.

## big_mac

The Economist's Big Mac index: dollar price of a Big Mac in the territory divided by the base's.
Covers about 75 countries (the euro-area price is spread over its members); rows older than three years are
dropped. Popular and easy to explain, but a non-tradable food basket **underprices rich Asian markets**:
at the time of writing Japan comes out near 0.5 while PPP says 0.69. Apply it if the user wants it and say
this. Territories without a Big Mac price use PPP.

## tiered

The user's own groups. `--tiers FILE`:

```json
{
  "tier_ratios": { "1": 1.0, "2": 0.7, "3": 0.4 },
  "default_tier": 1,
  "territories": { "BRA": 2, "MEX": 2, "IND": 3, "IDN": 3 }
}
```

Unlisted territories get `default_tier`. `tier_ratios` and `default_tier` are optional (defaults 1.0 / 0.7 / 0.4, tier 1).

## equalization

Ratio 1.0 everywhere: Apple's automatic prices. Use it as a baseline to see what a strategy changes.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--base` | schedule base, else USA | anchor territory |
| `--clamp-min` / `--clamp-max` | 0.30 / 1.30 | ratio bounds against the equalized price |
| `--flag-threshold` | 0.25 | flag `large-change` when the new price differs from the current by more than this |
| `--offline` | off | use only the bundled data snapshots |

## Data

Fetched live on every estimate and cached nowhere; on failure the bundled snapshot in `references/data/`
is used and the summary shows `snapshot` with its date. Sources: The Economist big-mac-data (GitHub),
World Bank Indicators API. Refresh the snapshot with `ruby scripts/refresh_data.rb`. Territory codes are
ISO 3166 alpha-3, as in App Store Connect; a territory whose code the sources do not know (for example a
disputed or unlisted region) falls back to equalization.
