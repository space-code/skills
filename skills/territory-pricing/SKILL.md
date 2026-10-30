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
**the whole subscription group** with one start date. One product per `plan.rb` run.

When the app sells several products that belong together (monthly and yearly subscriptions, a lifetime
unlock), price them as a **family**: the same strategy, base territory and endings for all of them, one start
date D (tomorrow or later), and the ladder check of step 4 before consent. A lifetime unlock is an in-app
purchase of type non-consumable; its period is `LIFETIME`.

### 3. Choose the strategy and settings

Ask the user (AskUserQuestion):

| Strategy | Use when |
|---|---|
| `gni_bands` (default) | Sensible default: three income bands 1.0x / 0.6x / 0.3x |
| `ppp` | Smooth, defensible curve from World Bank price levels |
| `big_mac` | The user asks for it; state the Asia caveat (Japan, Singapore, Hong Kong come out too cheap) |
| `tiered` | The user has their own country groups (`--tiers FILE`) |
| `equalization` | Baseline only: Apple's own prices, for comparison |

Ask in the same question round how the final price should look (price endings; details in
`references/strategies.md`):

| Endings | Meaning |
|---|---|
| `charm` (recommended) | Customary endings of each currency: .99 or .49 for USD, EUR, GBP and most cent currencies, .90 for BRL and ILS, .98 for SGD, round numbers in JPY, KRW and INR-style currencies. The price may move up to 5% away from the strategy's target to land on one. |
| `none` | The Price Point nearest to the target, whatever its ending |

Offer a different tolerance (default 5%) only if the user wants prettier or stricter prices
(`--endings-tolerance`).

Also confirm the base territory (default USA) and the guard rails: clamp 30%..130% of the equalized price,
flag changes above 25%. Defaults are fine unless the user objects.

### 4. Collect the data (read-only) and build the Price Proposal

Follow the playbook to collect, per territory: current price and price point, equalized price, and the list
of price points. Reading the price points is about 700 requests: use `scripts/collect_points.rb` in short
batches (run it again until it prints `done`, report progress after each run). Never run one long command
or your own sequential loop: the shell kills a command after 10 minutes and everything collected is lost.
Save the result as `plan-input.json` with `product.period` set (the subscription's `subscriptionPeriod`, such
as `ONE_MONTH` or `ONE_YEAR`, or `LIFETIME` for a lifetime unlock), then:

```bash
ruby "$SKILL_DIR/scripts/plan.rb" --input "$RUN/plan-input.json" --out "$RUN" --strategy <strategy> --base <TERRITORY> --endings <charm|none>
```

It writes `proposal.json` and `proposal.csv` and prints the summary. Show the user: counts, data sources
with dates, largest decreases and increases, skipped territories, and the path to `proposal.csv`. Point
out flags (`clamped`, `large-change`) and territories that used a fallback (`ratio_source` other than the
chosen strategy).

**Family check.** When you priced more than one product of the app, run the ladder check over all their
proposals:

```bash
ruby "$SKILL_DIR/scripts/ladder.rb" "$RUN_A/proposal.json" "$RUN_B/proposal.json" "$RUN_C/proposal.json"
```

Per territory it requires that a longer subscription costs more in total but less per month, and that a
lifetime unlock costs at least 2x the cheapest yearly cost (`--lifetime-min-years` to change it). Show the
violations next to the proposals. It exits 1 on a violation, 2 when a proposal has no `product.period`.

If the user edits `proposal.csv` (change `proposed`; empty the cell to leave a territory alone), run
`plan.rb --out "$RUN" --rebuild` and show the new summary. Prices like `9,90` or `$4.99` are understood; if a
cell cannot be read, `--rebuild` names it and changes nothing. A rebuild keeps the settings of the original
run. To try another strategy, run `plan.rb` again.

### 5. Get consent

Ask plainly: apply this proposal? Name the product, strategy, the number of territories that change and the
largest decrease. Wait for a clear yes. Anything else: adjust and re-run `plan.rb`.

**Do not ask for consent while the ladder check reports violations.** Fix them (edit `proposal.csv`, run
`plan.rb --rebuild`, run `ladder.rb` again) or change the settings. Only if the user
explicitly accepts the listed violations, save their answer as `ladder-accepted.txt` in the run folder and go on.

### 6. Write

Follow the playbook's write section for the product kind, always with `--write` and always from
`proposal.json` (the rows with a `price_point_id` that differs from `current_point_id`):

* **App price / in-app purchase:** one schedule with the base territory and every manual price, built by
  `schedule_body.rb` (`--start-date D` makes changed territories switch on day D; without it they change at
  once). For a family, write the subscriptions with start date D and the lifetime unlock with
  `--start-date D`, so all of them switch on the same day.
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
* New subscription prices start the next day at the earliest. An in-app purchase written without a start date
  changes at once, so a lifetime unlock written today is dearer or cheaper than the yearly plan for a day:
  give it the same start date.
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
