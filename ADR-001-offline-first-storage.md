# ADR-001: Offline-first on iOS via JSON file caches, not SQLite

| Status | Date       | Owner          |
|--------|------------|----------------|
| Accepted | 2026-05-23 | James Westgate |

## Context

The reference web application ([github.com/KateMorley/grid](https://github.com/KateMorley/grid)) is built around a MariaDB store that holds **raw half-hourly records** for the entire reporting history (~14 years × 17,520 half-hours × ~20 metrics ≈ tens of millions of rows). A `cron`-driven PHP script (`update.php`) appends the newest records every 5 minutes, and each page render runs SQL aggregations to compute the per-period averages displayed on the live site.

When designing the iOS port, we asked: should the app mirror this architecture on-device — local SQLite storing raw half-hourly records, with aggregations performed against the local DB on every render? That would produce the most faithful "offline-first" parallel of the server-side design: open the app, render whatever is in the DB, refresh in the background.

This ADR captures the storage decision so future contributors don't relitigate it.

## Decision

The iOS app uses **two JSON file caches on disk**, not SQLite, to deliver offline-first behaviour:

1. **`snapshot.json`** — fetched from this tools service (per [SPECIFICATION.md](SPECIFICATION.md)). Contains pre-aggregated **year** (daily means, 365 entries) and **allTime** (monthly means, ~150 entries) series. Refreshed roughly daily.
2. **`live.json`** — fetched directly from the three upstream APIs (Elexon, Carbon Intensity, NESO) by the app. Contains:
   - the point-in-time current KPIs (price, emissions, demand, generation, transfers, fuel mix, interconnector mix),
   - the **past-day** half-hourly series (48 points),
   - the **past-week** hourly series (168 points).
   Refreshed every 5 minutes while the app is foregrounded.

On launch, both files are read synchronously from disk and the UI renders immediately from whatever was last cached. A background `Task` then refreshes both, writes atomically (`*.tmp` → `rename`), and SwiftUI re-renders the affected views. If the network is unavailable, the app stays useful with the cached data plus a "Last updated *X minutes ago*" indicator.

SQLite (or SwiftData) is **not** introduced.

## Reasoning

The web app stores raw records because that's the cheapest format to keep up-to-date incrementally and to re-aggregate over arbitrary date ranges on the server. The iOS app has a **different workload**:

- It never aggregates over a user-chosen date range in v1; the four periods (day / week / year / allTime) are fixed and the aggregation for the long ones has already been done by this tools service.
- Year + allTime aggregates compress to roughly **20–30 kB gzipped JSON** — trivial to download whole.
- Past-day + past-week are tiny (a few hundred records). They can be fetched live and discarded; no benefit from persisting raw rows on-device.
- The remaining historical detail the web app keeps (raw half-hourly across 14 years, ~25 MB+ of records) **is not used by any v1 screen**. Storing it would inflate the install size and the disk footprint with no user-visible benefit.

A JSON-file cache delivers the same UX win as the web app's "DB always has something to show" — instant render from last-known state — without paying for SQLite, a schema, migration logic, an ORM dependency, or a re-aggregation pipeline on-device.

## Consequences

**Positive**
- No third-party dependency for storage. iOS bundle stays small.
- No schema migrations to maintain across app versions; cache format changes are handled by versioning the JSON keys (`schemaVersion` already exists in snapshot.json).
- Cache reads on launch are a single `Data(contentsOf:)` + `JSONDecoder` — fast and predictable.
- Cache writes are atomic via `tmp + rename`, so a crash mid-write cannot corrupt the cached state.
- Offline-first behaviour delivered with ~100 lines of caching code, no separate persistence layer to test.

**Negative / accepted trade-offs**
- Aggregations done on the server (this tools service) are now load-bearing for the iOS app. If the schema changes incompatibly, both ends must move together — already mitigated by `schemaVersion`.
- No ad-hoc historical querying on-device. If a future feature needs "show me the average price in June 2022", we either ask the tools service to add the range, ship a richer snapshot, or revisit this decision.
- The full historical archive lives on the tools server only. Users with no network on first launch get no historical data until the snapshot is fetched at least once (the live data still works via the upstream APIs, just without trend charts).

## Alternatives considered

### A. Full SQLite mirror of the web app
Local SQLite database with raw half-hourly records, populated on first launch by a bulk download (~25 MB), incrementally updated every 5 minutes thereafter. Aggregations computed by SQL queries on-device.

Rejected because:
- First-launch download is heavy (~25 MB) for a feature most users won't notice.
- Adds a SQLite dependency (GRDB / SwiftData) and a schema-migration story for every model change.
- Re-implements the same aggregation that the tools service already performs once, server-side.
- No v1 feature requires the granularity it would unlock.

### B. SQLite for live + snapshot.json for historical (hybrid)
Use SQLite only for the past-day + past-week half-hourly records (so we can do incremental row appends rather than full payload replacement), keep snapshot.json for year + allTime.

Rejected because:
- The "diff" benefit is marginal: past-day = 48 rows, past-week = 168 rows. Full replacement every 5 minutes is cheaper than maintaining append logic.
- Still pulls in the SQLite dependency for very little gain.

### C. Status quo SQLite via Apple's SwiftData
SwiftData wraps SQLite with no extra dependencies on iOS 17+. Cheap to add in theory.

Rejected for the same reason as A: nothing in v1 needs querying flexibility that JSON-in-memory can't provide. SwiftData is on the table for v2 if and when we add custom date ranges or per-record drilldown.

## When to revisit

This decision should be revisited if any of these become true:

- A feature requires querying arbitrary date ranges or filtering by timestamp/fuel/region in a way that's awkward against the four pre-aggregated buckets.
- The snapshot.json wire size grows past ~500 kB (which would suggest we've outgrown columnar JSON).
- We add multi-region (England / Scotland / Wales) drilldown that multiplies the data volume.
- A future iOS feature requires offline writes (e.g. user-bookmarked timestamps), where SQLite's transactional model becomes useful.

## Related

- [SPECIFICATION.md](SPECIFICATION.md) — the backfill snapshot service contract.
