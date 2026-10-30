# App Store Connect pricing endpoints

What the scripts call, per product kind. Shapes follow Apple's App Store Connect API documentation.

| | App price | In-app purchase | Subscription |
|---|---|---|---|
| Current prices | `GET /v1/apps/{id}/appPriceSchedule`, then `/v1/appPriceSchedules/{sid}/manualPrices` and `/automaticPrices` (`include=appPricePoint,territory`) | `GET /v2/inAppPurchases/{id}/iapPriceSchedule`, then `/v1/inAppPurchasePriceSchedules/{sid}/manualPrices` and `/automaticPrices` | `GET /v1/subscriptions/{id}/prices` (`include=subscriptionPricePoint,territory`) |
| Base territory | `/v1/appPriceSchedules/{sid}/baseTerritory` | `/v1/inAppPurchasePriceSchedules/{sid}/baseTerritory` | none; chosen by the user (`--base`) |
| Price points of a territory | `GET /v1/apps/{id}/appPricePoints?filter[territory]=X` | `GET /v2/inAppPurchases/{id}/pricePoints?filter[territory]=X` | `GET /v1/subscriptions/{id}/pricePoints?filter[territory]=X` |
| Equalized prices | `GET /v3/appPricePoints/{pp}/equalizations` | `GET /v1/inAppPurchasePricePoints/{pp}/equalizations` | `GET /v1/subscriptionPricePoints/{pp}/equalizations` |
| Write | `POST /v1/appPriceSchedules` | `POST /v1/inAppPurchasePriceSchedules` | `POST /v1/subscriptionPrices`, one per territory |
| Territory availability (best effort) | `/v1/apps/{id}/appAvailabilityV2` -> `/v2/appAvailabilities/{id}/territoryAvailabilities` | `/v2/inAppPurchases/{id}/inAppPurchaseAvailability` -> `.../availableTerritories` | `/v1/subscriptions/{id}/subscriptionAvailability?include=availableTerritories` |

Availability is read best effort: if Apple's answer cannot be read, every territory is treated as available
and a warning is printed.

## Writes

**App and IAP**: one POST with `baseTerritory` and a `manualPrices` entry (an `included` `appPrices` /
`inAppPurchasePrices` resource with a temporary `${priceN}` id) for every territory. A schedule posted without the
per-territory prices drops them back to Apple's automatic prices, so the scripts never post the base alone.
Territories left out of the proposal (unavailable, no price points) follow the automatic prices.

**Subscription**: `POST /v1/subscriptionPrices` with `startDate` (default tomorrow) and
`preserveCurrentPrice` (default `true`: existing subscribers keep their price). There is no bulk endpoint.
Price changes that have taken effect cannot be reverted; scheduled ones can be cancelled
(`DELETE /v1/subscriptionPrices/{id}`), which is what `--rollback` does first.

## Verification

After a write `apply.rb` re-reads the product with the same calls as the snapshot and compares the price
point in effect (or, for subscriptions, a scheduled entry with the same start date) to the proposal.
Output: `after.json` and `verify.json` next to the proposal.

## Rate limits and errors

The client retries HTTP 429 and 5xx with backoff (honoring `Retry-After`), up to four attempts. An
estimate for one product reads about 175 price-point lists, one request per territory, so it takes a minute or two.
`401` means the key does not match its ids, `403` means the key role is too low.

## Known unknowns

The documentation does not show every response of `automaticPrices` and the IAP availability endpoints. If a
current price cannot be resolved, the table shows `n/a` for it and treats the territory as changed. The
scripts were checked against stubbed responses in this documented shape and against the live API only for
authentication; run a dry run on a real product before the first write.
