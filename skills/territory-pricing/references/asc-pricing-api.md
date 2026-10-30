# Playbook: App Store Connect pricing calls

You call the API with `scripts/asc.rb`. Shapes follow Apple's App Store Connect API documentation; the
points marked **unverified** have not been confirmed against the live API.

```bash
A="ruby $SKILL_DIR/scripts/asc.rb"
$A GET '/v1/apps?limit=1'                       # one request
$A GET '/v1/subscriptions/42/prices?limit=200' --paginate   # follows links.next, merges data + included
$A POST /v1/subscriptionPrices @body.json --write           # writes need --write and a JSON body or @file
```

Brackets in query strings must be percent-encoded: `filter%5Bterritory%5D=USA`. In Ruby,
`require "#{ENV['SKILL_DIR']}/scripts/asc"` gives you `Asc.request`, `Asc.paginate`, `Asc.path` (adds `&` when the
base already has a query) and `Asc.index_included` for a throwaway collection script (keep it in the scratchpad, not in the repo).

## Endpoints

| | App price | In-app purchase | Subscription |
|---|---|---|---|
| Current prices | `GET /v1/apps/{id}/appPriceSchedule`, then `/v1/appPriceSchedules/{sid}/manualPrices` and `/automaticPrices` (`include=appPricePoint,territory`) | `GET /v2/inAppPurchases/{id}/iapPriceSchedule`, then `/v1/inAppPurchasePriceSchedules/{sid}/manualPrices` and `/automaticPrices` | `GET /v1/subscriptions/{id}/prices?include=subscriptionPricePoint,territory` |
| Base territory | `/v1/appPriceSchedules/{sid}/baseTerritory` | `/v1/inAppPurchasePriceSchedules/{sid}/baseTerritory` | none; ask the user (default USA) |
| Price points of a territory | `GET /v1/apps/{id}/appPricePoints?filter[territory]=X` | `GET /v2/inAppPurchases/{id}/pricePoints?filter[territory]=X` | `GET /v1/subscriptions/{id}/pricePoints?filter[territory]=X` |
| Equalized prices of a base point | `GET /v3/appPricePoints/{pp}/equalizations?include=territory` | `GET /v1/inAppPurchasePricePoints/{pp}/equalizations` | `GET /v1/subscriptionPricePoints/{pp}/equalizations?include=territory` |
| Write | `POST /v1/appPriceSchedules` | `POST /v1/inAppPurchasePriceSchedules` | `POST /v1/subscriptionPrices`, one per territory |
| Products of an app | the app itself | `GET /v1/apps/{id}/inAppPurchasesV2` | `GET /v1/apps/{id}/subscriptionGroups`, then `/v1/subscriptionGroups/{gid}/subscriptions` |

Each price point has `attributes.customerPrice` (a string) and a `territory` relationship; the territory's
`attributes.currency` comes with `include=territory`. A price resource links to its price point through the
relationship `appPricePoint` / `inAppPurchasePricePoint` / `subscriptionPricePoint`; resolve it in `included`.
A price whose `startDate` is in the future is a scheduled change, not the price in effect.

## Collecting the data for `plan.rb`

Build `plan-input.json` (format in `scripts/plan.rb`'s header):

1. Read the current prices; per territory take the price in effect (no `startDate` or one in the past, and
   no `endDate` in the past): `current` (a number), `current_point_id`, `currency`.
2. Read the price points of the base territory. **If `current_point_id` of the base is not in that list,
   the price sits on a legacy point: use the listed point with the same price as the base point.** Calling
   `equalizations` with a legacy id returns 404 ("does not correspond to a valid pricePoint or was
   deprecated").
3. Read the equalizations of that base point: `equalized` and `currency` per territory (the base territory
   itself may be missing; use its current price).
4. For every territory read its price points: `points: [{"id", "price"}]` with `price` as a number. This is
   the slow part, see "Reading price points in batches" below. Do not write your own sequential loop.
5. `available` is true unless you verified the territory is not sold. **Do not mark territories unavailable
   from an empty or failed availability read**: an earlier version did exactly that and marked all 175
   territories unavailable. Availability endpoints (**unverified**): app
   `/v1/apps/{id}/appAvailabilityV2` then `/v2/appAvailabilities/{id}/territoryAvailabilities`; IAP
   `/v2/inAppPurchases/{id}/inAppPurchaseAvailability` then `.../availableTerritories`; subscription
   `/v1/subscriptions/{id}/subscriptionAvailability` then `/v1/subscriptionAvailabilities/{id}/availableTerritories`.
   If you cannot read availability reliably, leave `available` true and tell the user.

Put `"product": {"kind", "id", "name", "period"}` and `"base_territory"` at the top of the file. `period` is what
`ladder.rb` compares: a subscription's `attributes.subscriptionPeriod` (`ONE_WEEK`, `ONE_MONTH`, `TWO_MONTHS`,
`THREE_MONTHS`, `SIX_MONTHS`, `ONE_YEAR`; the products list shows it) or `LIFETIME` for a lifetime unlock
(an in-app purchase with `inAppPurchaseType` `NON_CONSUMABLE`).

### Reading price points in batches

A subscription has about 800 price points per territory and Apple returns 200 per page, so the sweep is about
175 x 4 = 700 requests, roughly 12 minutes one after another. One long command is killed by the shell after
10 minutes and loses everything, so sweep once, in short resumable commands, and slice locally afterwards.

1. Write the territory codes you need (the keys of the current prices) to `$RUN/territories.json`.
2. Run, repeating until it prints `done` (each run reads one batch of 40 territories in 6 parallel threads,
   about 30 seconds, and saves every territory to `$RUN/points/<TERRITORY>.json`):

   ```bash
   ruby "$SKILL_DIR/scripts/collect_points.rb" "$RUN" /v1/subscriptions/<ID>/pricePoints
   ```

   Path per kind: `/v1/apps/<ID>/appPricePoints`, `/v2/inAppPurchases/<ID>/pricePoints`.
3. After every run tell the user the progress line (`80/175 territories saved`). If a run reports `failed:`
   territories, run it again: finished territories are skipped, only the failed ones are retried. Persistent
   failures (HTTP 401/403) are not retried by waiting; report them.
4. Build `plan-input.json` from the saved files with a short script, then call `plan.rb`. Never re-read the API
   because the analysis changed; answer follow-ups from the files.

Budget: Apple limits requests per key (about 3600 an hour, unverified), so a full sweep uses a noticeable part of
it. Reuse `$RUN/points/` when you re-run a plan for the same product on the same day; do not sweep twice.

## Writing

Only after consent, always with `--write`; save every request body in the run folder.

**App and in-app purchase: one request, built by `schedule_body.rb`.**

```bash
ruby "$SKILL_DIR/scripts/schedule_body.rb" --proposal "$RUN/proposal.json" --kind app --id <APP_ID> [--start-date D] > "$RUN/body.json"
ruby "$SKILL_DIR/scripts/asc.rb" POST /v1/appPriceSchedules @"$RUN/body.json" --write
```

Use `--kind iap --id <IAP_ID>` and `POST /v1/inAppPurchasePriceSchedules` for an in-app purchase. Look at
`body.json` before posting. It holds the base territory and a `manualPrices` entry for every territory that has a
`price_point_id` (changed or not). A territory `plan.rb` skipped (unavailable, no equalized price, no price points)
carries its **current** point in that field, so its manual price survives; only a territory with no current price at
all has none and falls back to Apple's automatic price.

* **Without `--start-date`** every price takes effect at once.
* **With `--start-date D`** (after today, UTC) a territory whose price changes keeps its current point until D and
  switches on D; unchanged territories keep one immediate price. App prices use `startDate` / `endDate` on the old
  and new entry, in-app purchase prices a `startDate` pair, as in Apple's examples. **This dated form is not
  verified against the live API**: try it on a non-critical in-app purchase first and read the schedule back.

The body looks like this (an app, immediate; `schedule_body.rb` writes it for you):

```json
{
  "data": {
    "type": "appPriceSchedules",
    "attributes": {},
    "relationships": {
      "app": { "data": { "type": "apps", "id": "<APP_ID>" } },
      "baseTerritory": { "data": { "type": "territories", "id": "USA" } },
      "manualPrices": { "data": [{ "type": "appPrices", "id": "${price0}" }] }
    }
  },
  "included": [
    { "type": "appPrices", "id": "${price0}", "attributes": { "startDate": null },
      "relationships": { "appPricePoint": { "data": { "type": "appPricePoints", "id": "<PRICE_POINT_ID>" } } } }
  ]
}
```

For an in-app purchase the names change: `inAppPurchasePriceSchedules`, relationship `inAppPurchase` (type
`inAppPurchases`), prices `inAppPurchasePrices` with the price point relationship `inAppPurchasePricePoint`, and each
price also names its product in `inAppPurchaseV2`. Never post the base alone: that drops every per-territory price
back to Apple's automatic one.

**Subscription: one request per territory.**

```json
{ "data": { "type": "subscriptionPrices",
    "attributes": { "startDate": "YYYY-MM-DD", "preserveCurrentPrice": true },
    "relationships": {
      "subscription": { "data": { "type": "subscriptions", "id": "<SUBSCRIPTION_ID>" } },
      "subscriptionPricePoint": { "data": { "type": "subscriptionPricePoints", "id": "<PRICE_POINT_ID>" } } } } }
```

Order: (1) second explicit yes with the irreversibility warning; (2) `startDate` = tomorrow or later, the
**same** for every subscription of the group; (3) canary on 1-2 territories, GET them back, show the user;
(4) the rest. Only territories whose `price_point_id` differs from `current_point_id`. Keep a log of what you
wrote so a rerun resumes. `preserveCurrentPrice: true` keeps existing subscribers on their price; `false`
triggers Apple's price-increase consent flow and only on the user's explicit request.

## A family of products (subscriptions plus a lifetime unlock)

Price the products with the same strategy, base territory and endings, one `plan.rb` run each, then check the
ladder across all their proposals with `ladder.rb` (details in `SKILL.md`, step 4); consent is blocked while it
reports violations. Write them so they all switch on one day D (tomorrow or later):

1. each subscription: `startDate` D, canary, then the rest;
2. the lifetime unlock: `schedule_body.rb ... --kind iap --start-date D`.

Without the shared date an in-app purchase written today changes at once while the subscriptions change tomorrow, so
for a day the yearly plan could cost more than the lifetime unlock.

## Verifying

GET the prices back with the same calls as in "Collecting" and compare the price point in effect (for
subscriptions: the scheduled entry with the same `startDate`; for an app or in-app purchase written with
`--start-date`: the entry with that `startDate` in the schedule's `manualPrices`) with `proposal.json`. Report counts
and every mismatch.

## Rollback

`proposal.json` rows carry `current_point_id` (resolved to a listed point). App/IAP: write one schedule with
those points. Subscriptions: first `DELETE /v1/subscriptionPrices/{id} --write` for each still-scheduled
change you created (**unverified** endpoint), then write the old points as a new change only where the price in
effect differs. Never delete scheduled changes that existed before your run.

## Rate limits and errors

`asc.rb` retries 429 and 5xx with backoff. `401`: key id, issuer id and `.p8` do not belong together.
`403`: key role too low (needs App Manager or Admin). `404` on a price point: legacy point, see above.
