---
name: territory-pricing
description: Sets worldwide per-territory prices for an iOS app, in-app purchase or auto-renewable subscription in App Store Connect. Computes a Price Proposal with a chosen pricing strategy (GNI bands, Big Mac index, PPP, tiered, Apple equalization), shows it, and writes to App Store Connect only after explicit consent. Trigger on "territory pricing", "localize prices", "regional pricing", "PPP pricing", "Big Mac index", "worldwide prices", or "региональные цены".
---

# Territory Pricing

You price one App Store product per territory. The user always sees the estimate first; nothing is
written to App Store Connect until they agree. You drive the App Store Connect API yourself through
`scripts/asc.rb`; `scripts/plan.rb` does the arithmetic so you never compute 175 prices by hand.

`SKILL_DIR` below is the folder that holds this file. Read `references/asc-pricing-api.md` (endpoints,
how to collect the data, how to write) before step 4, and `references/strategies.md` before step 3.

## Terms

* **Territory**: an App Store storefront (USA, BRA, JPN, ...), about 175 of them.
* **Base territory**: the territory whose current price anchors the plan, usually USA.
* **Equalized price**: what Apple derives for a territory from the base price at market exchange rates.
* **Price point**: one of the fixed prices Apple allows in a territory. A free-form price does not exist.
* **Pricing strategy**: how the equalized price is scaled per territory.
* **Price Proposal**: the table territory, current price, proposed price point. This is what the user approves.

## Hard rules

1. **Estimate before write.** Everything up to the Price Proposal is read-only (`asc.rb GET`, `plan.rb`).
2. **`--write` only after the user said yes** to the Price Proposal shown in this conversation. An earlier
   "yes" for another proposal or product does not count. `asc.rb` refuses POST/PATCH/DELETE without it.
3. **Never touch the key.** Do not read, print, copy or move the `.p8`. Never put it in a repository.
4. **Prices only.** Never change which territories a product is sold in.
5. **A 2xx is not proof.** After every write, GET the prices back and report only what that read confirms.
6. Keep working files (plan input, proposal, request bodies) in a run folder
   `./territory-pricing/<bundle-id>/<YYYY-MM-DD-HHMM>/`; offer to add `territory-pricing/` to `.gitignore`.

## Workflow

### 1. Check the key (always first)

```bash
bash "$SKILL_DIR/scripts/check_setup.sh"
```

Stop on any `FAIL` and walk the user through the fix it prints (`references/setup.md`). The key lives in
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, the Issuer ID in `~/.appstoreconnect/config.json`.
Continue only on `setup OK`.

### 2. Pick the app and the product

List apps with `asc.rb GET '/v1/apps?limit=200&fields[apps]=name,bundleId' --paginate` (filter by the bundle
id from the Xcode project if there is one), then list the app's products (app price, in-app purchases,
subscription groups). Commands are in the playbook. Ask which product to price. For subscriptions price
**the whole subscription group** with one start date, so a yearly plan never sits above a lifetime unlock
for a day. One kind and one group per run.

### 3. Choose the strategy and settings

Ask the user (AskUserQuestion):

| Strategy | Use when |
|---|---|
| `gni_bands` (default) | Sensible default: three income bands 1.0x / 0.6x / 0.3x |
| `ppp` | Smooth, defensible curve from World Bank price levels |
| `big_mac` | The user asks for it; state the Asia caveat (Japan, Singapore, Hong Kong come out too cheap) |
| `tiered` | The user has their own country groups (`--tiers FILE`) |
| `equalization` | Baseline only: Apple's own prices, for comparison |

Also confirm the base territory (default USA) and the guard rails: clamp 30%..130% of the equalized price,
flag changes above 25%. Defaults are fine unless the user objects.

### 4. Collect the data (read-only) and build the Price Proposal

Follow the playbook to collect, per territory: current price and price point, equalized price, and the list
of price points. Save it as `plan-input.json`, then:

```bash
ruby "$SKILL_DIR/scripts/plan.rb" --input "$RUN/plan-input.json" --out "$RUN" --strategy <strategy> --base <TERRITORY>
```

It writes `proposal.json` and `proposal.csv` and prints the summary. Show the user: counts, data sources
with dates, largest decreases and increases, skipped territories, and the path to `proposal.csv`. Point
out flags (`clamped`, `large-change`) and territories that used a fallback (`ratio_source` other than the
chosen strategy).

If the user edits `proposal.csv` (change `proposed`; empty the cell to leave a territory alone), run
`plan.rb --out "$RUN" --rebuild` and show the new summary. To try another strategy, run `plan.rb` again.

### 5. Get consent

Ask plainly: apply this proposal? Name the product, strategy, the number of territories that change and the
largest decrease. Wait for a clear yes. Anything else: adjust and re-run `plan.rb`.

### 6. Write

Follow the playbook's write section for the product kind, always with `--write` and always from
`proposal.json` (the rows with a `price_point_id` that differs from `current_point_id`):

* **App price / in-app purchase:** one schedule with the base territory and every manual price.
* **Subscription:** price changes that took effect cannot be undone, so get a **second, separate yes**
  with that warning, write 1-2 canary territories first, read them back and show the user, then the rest
  with the **same** start date. Existing subscribers keep their price (`preserveCurrentPrice: true`) unless
  the user explicitly asks otherwise.

### 7. Verify and report

GET the prices back and compare with `proposal.json`. Report the count that matched and every mismatch or
failure verbatim. For subscriptions the old price stays visible until the start date; that is a scheduled
change, not a failure.

### Rollback

`proposal.json` keeps each territory's `current_point_id`. Rolling back means writing those points again
(app/IAP: one schedule; subscriptions: cancel the still-scheduled `subscriptionPrices` first). A subscription
change that already took effect can only be superseded by a new change, not undone; say that first.

## Gotchas that cost money

* Posting a new base price alone wipes every per-territory price. Always send the base and all manual prices together.
* New subscription prices start the next day at the earliest.
* A price in effect can sit on a **legacy price point** that Apple no longer lists; its equalizations
  return 404. `plan.rb` maps it onto the listed point with the same price, and the playbook does the same
  for the base point before reading equalizations.
* Territories with no data for the strategy fall back (Big Mac, then PPP, then equalization); the table
  says which one was used.
* Economic data comes from the bundled snapshot (`references/data/`); the summary prints its date. Refresh
  it with `ruby "$SKILL_DIR/scripts/refresh_data.rb"`.

## References

* `references/setup.md`: creating the API key and where it goes
* `references/strategies.md`: formulas, data sources, caveats, fallback chain
* `references/asc-pricing-api.md`: the playbook, endpoints per product kind, collecting data, writing, verifying
