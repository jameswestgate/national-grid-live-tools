# National Grid Live — Backfill Snapshot Service

Specification for a containerised service that aggregates historical UK electricity grid data into a single JSON file and serves it over HTTP for the National Grid Live iOS app to consume.

This document is **implementation-agnostic**. A reference implementation will be written in **C# / .NET 8** running in a single Docker container, but anything that satisfies the contracts below is conformant.

---

## 1. Why this service exists

The iOS app fetches **live** data (last 24 hours) directly from three public APIs. It cannot fetch historical data (Past Year, All Time) directly because:

- The public APIs are rate-limited and paginate in small windows (e.g. Carbon Intensity API caps at 14 days per request).
- 14+ years of half-hourly data is tens of megabytes — too much to download on every launch.
- Aggregating raw half-hourly records into daily/monthly buckets on-device is wasteful (every device repeats identical work).

This service performs the aggregation **once per day on a server**, writes the result to a single static JSON file, and serves that file. The iOS app fetches it once on first launch, caches it on disk, and re-checks for updates daily.

## 2. Architectural overview

One container, two concurrent responsibilities:

```
┌─────────────────────────────────────────────────────┐
│  Container                                          │
│                                                     │
│  ┌─────────────────┐         ┌──────────────────┐   │
│  │  Updater        │  writes │  HTTP server     │   │
│  │  (daily cron)   │ ──────► │  (always-on)     │   │
│  │                 │         │                  │   │
│  │  fetch → cache  │         │  GET /snapshot   │   │
│  │  → aggregate    │         │  GET /manifest   │   │
│  │  → write JSON   │         │  GET /healthz    │   │
│  └─────────────────┘         └──────────────────┘   │
│         │                            │              │
│         └────── shared volume ───────┘              │
│                  /data/                             │
│                    snapshot.json                    │
│                    manifest.json                    │
│                    cache/                           │
└─────────────────────────────────────────────────────┘
```

The updater and server share a volume (`/data`). The server only ever reads from it; the updater is the only writer. Both can run as background services within the same .NET host process (e.g. `IHostedService` + Kestrel).

## 3. Data sources

All three are **public, key-less, free**. HTTPS-only. No registration required. Verified 2026-05.

### 3.1 Elexon BMRS Insights API
- **Host:** `https://data.elexon.co.uk/bmrs/api/v1/`
- **Generation by fuel type (half-hourly, history)** — `/datasets/FUELHH?publishDateTimeFrom={ISO}&publishDateTimeTo={ISO}&format=json` — data available from 2009, but treat 2014-01-01 as reliable start.
- **Market index price** — `/balancing/pricing/market-index?from={ISO}&to={ISO}&dataProviders=APXMIDP&format=json` — data available from approximately 2018.
- Practical query window: 1 month per request to stay within response-size limits.
- Licence: free use; reproduce the attribution string verbatim where displayed:
  > *Contains BMRS data © Elexon Limited copyright and database right {year}.*

### 3.2 Carbon Intensity API
- **Host:** `https://api.carbonintensity.org.uk/`
- **24h intensity** — `/intensity/{ISO}/pt24h` — half-hourly resolution.
- **Bounded range** — `/intensity/{from-ISO}/{to-ISO}` — **max 14 days per request**, paginate by 14-day windows.
- Data available from 2018-05-10.
- Licence: CC BY 4.0 — attribute as:
  > *Carbon intensity data © National Grid ESO and the University of Oxford Department of Computer Science, used under CC BY 4.0.*

### 3.3 NESO Data Portal (National Energy System Operator)
- **Host:** `https://api.neso.energy/`
- **Demand + embedded solar/wind** — `/dataset/7a12172a-939c-404c-b581-a6128b74f588/resource/177f6fa4-ae49-4182-81ea-0c6b35f26ca6/download/demanddataupdate.csv`
- One CSV containing the entire historical dataset — single download, no pagination.
- Half-hourly resolution, data available from approximately 2009.
- Licence: NESO Open Licence — attribute as:
  > *Contains NESO Data Portal data, used under the NESO Open Licence.*

### 3.4 Behaviour when a source is unavailable for an early date
For dates before a given API's start date, fill the metric with `null`. The iOS app renders `null` gaps as broken-line segments in charts.

## 4. Output: `snapshot.json`

This is the **contract** between the service and the iOS app. Breaking changes must increment `schemaVersion`.

### 4.1 Schema (columnar)

```jsonc
{
  "schemaVersion": 1,
  "generated": "2026-05-23T22:00:00Z",     // when this snapshot was built
  "sources": {                              // attribution for the About screen
    "elexon":         "Contains BMRS data © Elexon Limited copyright and database right 2026.",
    "carbonIntensity":"Carbon intensity data © National Grid ESO and Oxford CS, used under CC BY 4.0.",
    "neso":           "Contains NESO Data Portal data, used under the NESO Open Licence."
  },

  "year": {
    "from": "2025-05-24",                   // inclusive
    "to":   "2026-05-23",                   // inclusive
    "granularity": "day",
    "dates":     ["2025-05-24", "..."],     // length = N
    "price":     [110.22, null, 98.4, ...], // £/MWh — daily mean, null if no data
    "emissions": [108, 96, null, ...],      // gCO₂/kWh — daily mean
    "demand":    [25.5, 26.1, ...],         // GW — daily mean
    "generation":[20.6, 21.3, ...],         // GW — daily mean
    "transfers": [4.9,  4.8,  ...],         // GW — daily mean (net imports)
    "fuels": {
      "gas":     [5.49, ...],               // GW — daily mean per fuel
      "wind":    [6.84, ...],
      "solar":   [4.43, ...],
      "nuclear": [...],
      "biomass": [...],
      "hydro":   [...],
      "coal":    [...],
      "pumped":  [...]                      // pumped storage net (can be negative)
    },
    "interconnectors": {
      "france":      [...],                 // GW — daily mean net flow
      "norway":      [...],
      "belgium":     [...],
      "denmark":     [...],
      "ireland":     [...],
      "netherlands": [...]
    }
  },

  "allTime": {
    "from": "2014-01",                      // YYYY-MM (inclusive)
    "to":   "2026-05",
    "granularity": "month",
    "dates":     ["2014-01", "..."],
    "price":     [38.2, null, ...],
    "emissions": [...],
    "demand":    [...],
    "generation":[...],
    "transfers": [...],
    "fuels":           { /* same keys as year.fuels */ },
    "interconnectors": { /* same keys as year.interconnectors */ }
  }
}
```

### 4.2 Encoding rules

- **JSON**, UTF-8, no trailing newline required.
- **Columnar format** — one parallel array per metric, all aligned to the `dates` array. This is ~10× smaller than per-day records and reads efficiently into Swift Charts.
- Numbers: at most **3 significant figures** server-side; do not pretty-print with whitespace in production output. Use `null` for missing data.
- Dates: `dates` entries in `year` use `YYYY-MM-DD`. `allTime` uses `YYYY-MM`.
- Final file should be **gzipped at the HTTP layer** (`Content-Encoding: gzip`) — expected wire size < 30 kB.

### 4.3 Versioning

If the schema must change in a backwards-incompatible way:
- Increment `schemaVersion`.
- Continue serving the previous version at `/v{N}/snapshot.json` for at least 90 days so older app builds keep working.

## 5. `manifest.json`

A tiny sidecar the iOS app polls to decide whether to re-download `snapshot.json`. Cheap to fetch (under 200 bytes).

```json
{
  "schemaVersion": 1,
  "generated":     "2026-05-23T22:00:00Z",
  "etag":          "8f3c2e1a",
  "sizeBytes":     112340
}
```

The app stores the last seen `generated` timestamp and only re-downloads `snapshot.json` when the manifest's `generated` is newer.

## 6. HTTP API

| Method | Path                | Purpose                          | Cache-Control                |
|--------|---------------------|----------------------------------|------------------------------|
| GET    | `/v1/snapshot.json` | The full historical snapshot     | `public, max-age=3600`       |
| GET    | `/v1/manifest.json` | Metadata for change detection    | `public, max-age=300`        |
| GET    | `/healthz`          | Liveness probe (always 200 OK)   | `no-store`                   |
| GET    | `/readyz`           | Readiness — 200 if snapshot exists, 503 otherwise | `no-store` |

### Headers on snapshot/manifest responses
- `Content-Type: application/json; charset=utf-8`
- `Content-Encoding: gzip`
- `ETag: "<sha256-of-body, first 16 chars>"`
- Honour `If-None-Match` and respond `304 Not Modified` when the ETag matches.

### CORS
- `Access-Control-Allow-Origin: *` — there are no secrets, and the site may want to embed the data later.

## 7. Updater

### 7.1 Schedule
- Run once per day at **02:00 UTC** (after Elexon's overnight settlement).
- On container start, **also run immediately** if no `snapshot.json` exists yet.
- Use the host's job scheduler or a `BackgroundService` with a timed loop. Do **not** rely on cron inside the container — embed the schedule in the application.

### 7.2 Pipeline

```
For each data source:
  for each date in [start_date .. yesterday] not already in cache/{source}/{date}.json:
    fetch the data window covering that date (with retry/backoff)
    aggregate to daily totals/means
    write cache/{source}/{date}.json atomically
Build year-section from cache (last 365 days)
Build allTime-section from cache (group days into months, average)
Compose snapshot.json
Write to /data/snapshot.json.tmp, fsync, rename to snapshot.json (atomic publish)
Compute SHA-256, write manifest.json the same way
```

### 7.3 Caching

- Cache directory: `/data/cache/{source}/{YYYY-MM-DD}.json`
- Cache entries are **immutable** once written for a finalised date (i.e. yesterday or earlier).
- The current day is never cached; it's re-fetched every run.
- A `--purge-cache` flag (or `PURGE_CACHE=1` env var) blows away the cache and refetches everything.

### 7.4 Retries & failure isolation

- Per-request: exponential backoff, up to **5 attempts**, base 2s, cap 60s.
- If a single date fails after retries: log, skip, leave the gap as `null` in the snapshot. Do not abort the whole run.
- If an **entire data source** is down for the run: publish the snapshot anyway with the affected metrics filled by the last good values from the previous snapshot + a warning in logs. Do **not** publish a snapshot with all-null arrays.

### 7.5 Rate limiting

Be polite — no source publishes a documented rate limit:
- Sleep 250 ms between successive requests to the same host.
- Run sources sequentially (Elexon → Carbon Intensity → NESO), not in parallel.

## 8. Observability

### 8.1 Structured logs (JSON to stdout)

```json
{"ts":"2026-05-23T02:00:01Z","level":"info","event":"updater.start"}
{"ts":"2026-05-23T02:00:02Z","level":"info","event":"fetch","source":"elexon","window":"2026-05-22","ok":true,"durationMs":342}
{"ts":"2026-05-23T02:00:10Z","level":"warn","event":"fetch","source":"carbonIntensity","window":"2026-05-22","ok":false,"attempt":3,"error":"timeout"}
{"ts":"2026-05-23T02:01:14Z","level":"info","event":"snapshot.published","sizeBytes":112340,"yearDays":365,"allTimeMonths":149}
```

### 8.2 Metrics (optional `/metrics` endpoint, Prometheus format)

- `snapshot_last_generated_timestamp_seconds` (gauge)
- `snapshot_size_bytes` (gauge)
- `updater_run_duration_seconds` (histogram, label `outcome=success|partial|failure`)
- `source_fetch_failures_total{source=...}` (counter)

## 9. Configuration (environment variables)

| Variable                 | Default                   | Purpose |
|--------------------------|---------------------------|---------|
| `DATA_DIR`               | `/data`                   | Where the snapshot, manifest, and cache live |
| `LISTEN_PORT`            | `8080`                    | HTTP port |
| `UPDATE_TIME_UTC`        | `02:00`                   | Daily update time, HH:MM, UTC |
| `ALL_TIME_START`         | `2014-01`                 | Earliest month to include in `allTime` |
| `YEAR_DAYS`              | `365`                     | Days in the rolling `year` section |
| `PURGE_CACHE`            | `0`                       | If `1`, wipe cache and re-fetch on next run |
| `LOG_LEVEL`              | `info`                    | `debug` \| `info` \| `warn` \| `error` |
| `HTTP_USER_AGENT`        | `national-grid-live-tools/1.0 (+contact)` | Sent on outbound requests |

## 10. Container

### 10.1 Image expectations

- Multi-stage build, runtime image based on `mcr.microsoft.com/dotnet/aspnet:8.0-alpine` (or equivalent slim base).
- Final image size target: **under 200 MB**.
- Runs as a non-root user. Owns `/data`.
- `EXPOSE 8080`.
- `HEALTHCHECK` calls `/healthz` every 30 seconds.

### 10.2 Volumes

- `/data` should be mounted as a persistent volume so the cache survives container restarts.

### 10.3 Example compose

```yaml
services:
  ngl-tools:
    image: ngl-tools:latest
    ports:
      - "8080:8080"
    volumes:
      - ngl-data:/data
    environment:
      ALL_TIME_START: "2014-01"
    restart: unless-stopped
volumes:
  ngl-data:
```

## 11. Reference fetch logic (pseudocode)

```pseudo
# Carbon Intensity — paginate in 14-day windows
function fetch_carbon_intensity(from_date, to_date):
  results = []
  cursor = from_date
  while cursor <= to_date:
    window_end = min(cursor + 13 days, to_date)
    url = "https://api.carbonintensity.org.uk/intensity/{cursor}T00:00Z/{window_end}T23:59Z"
    rows = http_get_json(url).data         # half-hourly
    results.extend(rows)
    cursor = window_end + 1 day
    sleep(250ms)
  return results

# Daily aggregation
function aggregate_daily(half_hourly_rows):
  by_date = group_by(row -> row.from[:10], half_hourly_rows)
  return { date: mean(rows.value) for date, rows in by_date }
```

## 12. Local development

Two ways to validate output without containerising:

1. **Run the CLI directly**: a one-shot `dotnet run -- generate-snapshot --out ./snapshot.json` builds the snapshot to a local file. Used by the maintainer to debug or to seed a checked-in fixture for the iOS app's tests.
2. **Run the full container**: `docker compose up` and curl `http://localhost:8080/v1/snapshot.json`.

## 13. Out of scope (deliberately)

- No authentication / API keys / user accounts.
- No write API. The service is read-only from the public's perspective.
- No live data — the iOS app fetches live data straight from the three sources.
- No regional or per-postcode emissions data — out of scope for v1.

## 14. Future work

- Push notifications when a new "coal-free streak" record is set.
- WebSub / Server-Sent Events feed for richer client updates.
- Additional snapshot formats: CSV export, MessagePack for smaller payloads.
- Optional `Region` parameter on Carbon Intensity endpoints to support a regional view in the app.

---

**Last reviewed:** 2026-05-23
**Owner:** James Westgate

Note: the commercial font can be bought here:
https://www.myfonts.com/collections/proza-font-bureau-roffa

The styles are:

