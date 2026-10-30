---
name: territory-pricing
description: Sets worldwide per-territory prices for an iOS app, in-app purchase or auto-renewable subscription in App Store Connect. Computes a Price Proposal with a chosen pricing strategy (GNI bands, Big Mac index, PPP, tiered, Apple equalization), shows it, and writes to App Store Connect only after explicit consent. Trigger on "territory pricing", "localize prices", "regional pricing", "PPP pricing", "Big Mac index", "worldwide prices", or "региональные цены".
---

# Territory Pricing

You price one App Store product per territory. The user always sees the estimate first;
nothing is written to App Store Connect until they agree.

## Terms

* **Territory**: an App Store storefront (USA, BRA, JPN, ...), about 175 of them.
* **Base territory**: the territory whose current price is the anchor, usually USA.
* **Equalized price**: what Apple derives for a territory from the base price at market exchange rates.
* **Price point**: one of the fixed prices Apple allows in a territory. A free-form price does not exist.
* **Pricing strategy**: how the equalized price is scaled per territory (see `references/strategies.md`).
* **Price Proposal**: the table territory, current price, proposed price point. This is what the user approves.

## Hard rules

1. **Estimate before write.** `estimate.rb` only reads. `apply.rb` is a dry run unless `--confirm`.
2. **`--confirm` only after the user said yes** to the Price Proposal you showed in this conversation. An earlier "yes" for another proposal or product does not count.
3. **Never touch the key.** Do not read, print, copy or move the `.p8`. Never put it in a repository.
4. **Prices only.** Never change which territories a product is sold in.
5. **A 2xx is not proof.** Report only what the read-back after the write confirmed.
6. Run scripts with absolute paths from this skill's directory; `SKILL_DIR` below is the folder holding this file.

## Workflow

### 1. Check the key (always first)

```bash
bash "$SKILL_DIR/scripts/check_setup.sh"
```

Stop on any `FAIL` and walk the user through the fix it prints (details in `references/setup.md`).
The key lives in `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, the Issuer ID in
`~/.appstoreconnect/config.json`. Continue only on `setup OK`.

### 2. Pick the app and the product

```bash
ruby "$SKILL_DIR/scripts/list_products.rb" --apps --bundle-id <bundle id from the Xcode project>
ruby "$SKILL_DIR/scripts/list_products.rb" --app <APP_ID>
```

If the working directory has an Xcode project, take the bundle id from it (`PRODUCT_BUNDLE_IDENTIFIER`);
otherwise list all apps. Ask which product to price: the app price, an in-app purchase, or a
subscription. For subscriptions, price **the whole subscription group** (every subscription in it)
with one start date, so a yearly plan never sits above a lifetime unlock for a day.
One kind and one group per run.

### 3. Choose the strategy and settings

Ask the user (AskUserQuestion). Read `references/strategies.md` for formulas and caveats first.

| Strategy | Use when |
|---|---|
| `gni_bands` (default) | Sensible default: three income bands 1.0x / 0.6x / 0.3x |
| `ppp` | Smooth, defensible curve from World Bank price levels |
| `big_mac` | The user asks for it; state the Asia caveat (Japan, Singapore, Hong Kong come out too cheap) |
| `tiered` | The user has their own country groups (`--tiers FILE`) |
| `equalization` | Baseline only: Apple's own prices, a comparison |

Also confirm the base territory (default: the schedule's base, else USA) and the guard rails:
clamp 30%..130% of the equalized price (`--clamp-min/--clamp-max`), flag changes above 25%
(`--flag-threshold`). Defaults are fine unless the user objects.

### 4. Estimate (read-only)

```bash
RUN="./territory-pricing/<bundle-id>/$(date +%Y-%m-%d-%H%M)"
ruby "$SKILL_DIR/scripts/estimate.rb" --kind <app|iap|subscription> --id <ID> \
     --strategy <strategy> --base <TERRITORY> --out "$RUN"
```

It writes `before.json` (current prices, the rollback point), `proposal.json`, `proposal.csv` and
`price_points.json` into `$RUN`. For a subscription group run it once per subscription.

Show the user the printed summary: counts, data sources with dates, largest decreases and increases,
skipped territories, plus the path to `proposal.csv`. Point out flags (`clamped`, `large-change`),
territories that used a fallback (`ratio_source` other than the chosen strategy), and any warning
about already scheduled price changes. Offer to add `territory-pricing/` to `.gitignore`.

If the user edits `proposal.csv` (change `proposed`; empty it to leave a territory alone), rebuild:

```bash
ruby "$SKILL_DIR/scripts/estimate.rb" --out "$RUN" --rebuild
```

Then show the new summary. To try another strategy, estimate again into a new `$RUN`.

### 5. Get consent

Ask plainly: apply this proposal? Name the product, strategy, number of territories that change and
the largest decrease. Wait for a clear yes. Anything else: adjust and re-estimate.

### 6. Apply

Dry run first and show it:

```bash
ruby "$SKILL_DIR/scripts/apply.rb" --proposal "$RUN/proposal.json"
```

**App price and in-app purchase** (one schedule, all prices at once, effective immediately):

```bash
ruby "$SKILL_DIR/scripts/apply.rb" --proposal "$RUN/proposal.json" --confirm
```

**Subscription** (one POST per territory; price changes that took effect cannot be undone):

1. Warn explicitly and get a **second, separate yes**: new prices start on the start date, apply to
   new subscribers, and cannot be reverted once live. By default existing subscribers keep their
   price (`preserveCurrentPrice: true`); `--no-preserve` triggers Apple's price-increase consent
   flow and needs the user to ask for it.
2. Canary on 1-2 territories, then check its read-back with the user:
   ```bash
   ruby "$SKILL_DIR/scripts/apply.rb" --proposal "$RUN/proposal.json" --confirm --phase canary --start-date <YYYY-MM-DD>
   ```
3. Only if the canary matches, apply the rest with the **same** `--start-date`:
   ```bash
   ruby "$SKILL_DIR/scripts/apply.rb" --proposal "$RUN/proposal.json" --confirm --phase rest --start-date <same date>
   ```
   Do this for every subscription of the group with that date. `apply-log.json` makes a rerun resume
   instead of repeating territories.

### 7. Verify and report

`apply.rb` reads the prices back (`after.json`, `verify.json`). Report the count that matched and every
mismatch or failure verbatim. For subscriptions the old price stays visible until the start date; that
is a scheduled change, not a failure.

### Rollback

```bash
ruby "$SKILL_DIR/scripts/apply.rb" --rollback "$RUN/before.json"            # dry run
ruby "$SKILL_DIR/scripts/apply.rb" --rollback "$RUN/before.json" --confirm
```

For subscriptions this first cancels still-scheduled changes. A change that already took effect cannot
be undone, only superseded by a new change, so say that before running it.

## Gotchas that cost money

* Posting a new base price alone wipes every per-territory price. The scripts send the base and all
  manual prices together; never improvise a base-only call.
* New subscription prices start the next day at the earliest.
* Territories with no data for the chosen strategy fall back (Big Mac, then PPP, then equalization)
  and the table says which one was used.
* Economic data is fetched live and falls back to the bundled snapshot; the summary prints each source and
  its date. Refresh the snapshot with `ruby "$SKILL_DIR/scripts/refresh_data.rb"`.

## References

* `references/setup.md`: creating the API key and where it goes
* `references/strategies.md`: formulas, data sources, caveats, fallback chain
* `references/asc-pricing-api.md`: endpoints per product kind and how the scripts use them
