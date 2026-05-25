# National Grid Live — GitHub Actions Implementation Spec

This is the implementation guide for the **GitHub Actions + GitHub Pages** variant of the National Grid Live Backfill Snapshot Service.

**The behavioural contract — data sources, output schema, aggregation rules, attribution strings, retry policy, configuration semantics — is defined in [`SPECIFICATION.md`](./SPECIFICATION.md) and is authoritative. This document describes only the deltas needed to deploy that behaviour using GitHub Actions and GitHub Pages instead of a long-running container.**

Read `SPECIFICATION.md` first. Then read this document for the deltas. When the two documents appear to disagree, `SPECIFICATION.md` wins on *what* the service does; this document wins on *how* it is deployed.

---

## 1. What changes vs the original spec

The original spec assumes a long-running container with an in-process HTTP server. This variant replaces that with:

- The **updater** runs as a scheduled GitHub Actions workflow.
- The **HTTP server** is replaced by **GitHub Pages**, serving the committed `snapshot.json` and `manifest.json` as static files behind GitHub's CDN.
- The **cache** lives in the git repository (committed JSON files), not on a mounted volume.
- The **container is gone.** The updater runs the same .NET 8 CLI described in §12.1 of the original spec, but as a step inside an Actions workflow rather than as a hosted process.

Sections of `SPECIFICATION.md` that change in this variant:

| Section | Status in this variant |
|---|---|
| §6 `/healthz`, `/readyz` | **Removed.** Pages availability is the health signal; staleness is detected by the canary workflow (§6 below). |
| §6 `Cache-Control` headers | **Not configurable.** GitHub Pages sets its own. The iOS app uses `manifest.json` for explicit invalidation, so this is acceptable. |
| §6 `ETag` (sha256-derived) | **Not the wire ETag.** Pages emits its own ETag. The internal `etag` field in `manifest.json` remains authoritative for the iOS app. |
| §6 CORS, gzip | **Provided automatically by Pages.** No action needed. |
| §7.1 "run immediately on container start" | **Replaced by `workflow_dispatch`** (manual trigger) for the first run and for recovery. |
| §8.2 Prometheus metrics endpoint | **Removed.** Already optional in the original. |
| §10 Container | **Optional, dev-only.** The Dockerfile may remain for local development per §12.2 of the original, but is not the deployment artefact. |

All other sections of `SPECIFICATION.md` — data sources (§3), output schema (§4), manifest schema (§5), updater pipeline (§7.2), caching semantics (§7.3), retries (§7.4), rate limiting (§7.5), structured logs (§8.1), env vars (§9) — apply unchanged.

---

## 2. Required deliverables

1. A **.NET 8 console application** that produces `snapshot.json` and `manifest.json` conforming to §4 and §5 of `SPECIFICATION.md`.
2. A **GitHub Actions workflow** that runs the application daily and publishes outputs to GitHub Pages.
3. A **staleness-check workflow** that fails loudly if the snapshot stops updating.
4. **Setup documentation** in `README.md` covering first deploy, recovery, and local dev.
5. A **schema validation step** in CI that catches breaking changes before publish.

---

## 3. Repository layout

```
.
├── .github/
│   └── workflows/
│       ├── update-snapshot.yml      # daily cron + workflow_dispatch
│       ├── staleness-check.yml      # canary; alerts if snapshot goes stale
│       └── pr-validate.yml          # PRs build, test, and run the CLI without publishing
├── src/
│   └── NationalGridLive.Updater/
│       ├── Program.cs                # entry point + arg parsing
│       ├── NationalGridLive.Updater.csproj
│       ├── Sources/
│       │   ├── ElexonClient.cs       # §3.1
│       │   ├── CarbonIntensityClient.cs  # §3.2
│       │   └── NesoClient.cs         # §3.3
│       ├── Aggregation/
│       │   └── DailyAggregator.cs    # §11 pseudo-code, real impl
│       └── Snapshot/
│           ├── SnapshotBuilder.cs    # builds the §4.1 document
│           └── ManifestBuilder.cs    # builds the §5 document
├── tests/
│   └── NationalGridLive.Updater.Tests/
│       ├── fixtures/                 # canned API responses
│       └── golden/                   # checked-in snapshot.json for byte-equality test
├── cache/                            # per-source per-date cache (COMMITTED to git)
│   ├── elexon/
│   ├── carbonIntensity/
│   └── neso/
├── public/                           # served by Pages — the deployment artefact
│   ├── v1/
│   │   ├── snapshot.json
│   │   └── manifest.json
│   └── index.html                    # human landing page; attribution + links
├── SPECIFICATION.md                  # original contract — DO NOT modify
├── specifications-github.md          # this document
└── README.md
```

The published Pages root corresponds to the `public/` directory. The iOS app fetches:

- `https://<user>.github.io/<repo>/v1/snapshot.json`
- `https://<user>.github.io/<repo>/v1/manifest.json`

Optionally also exposed via jsDelivr for CDN resilience:

- `https://cdn.jsdelivr.net/gh/<user>/<repo>@main/public/v1/snapshot.json`

---

## 4. The CLI

A single executable with one subcommand. Same binary used in CI and locally per §12.1 of the original spec.

```
NationalGridLive.Updater generate-snapshot \
  --cache-dir ./cache \
  --out-dir ./public/v1 \
  [--purge-cache] \
  [--year-days 365] \
  [--all-time-start 2014-01]
```

**Behaviour** (this is just §7.2 of the original spec, restated for the CLI surface):

1. For each source in order (Elexon → Carbon Intensity → NESO; sequential per §7.5):
   - For each date from `--all-time-start` through yesterday UTC that is **not** already in `cache/{source}/{date}.json`: fetch with exponential backoff per §7.4, aggregate to daily means per §11, write `cache/{source}/{date}.json.tmp`, fsync, rename atomically.
   - Today's data is fetched every run and never cached (per §7.3).
2. Build the `year` section from the last `--year-days` days of cache.
3. Build the `allTime` section by grouping cache days into months and averaging.
4. Compose `snapshot.json` per §4.1, applying the encoding rules in §4.2 (3 significant figures, no whitespace, `null` for missing data).
5. Write `public/v1/snapshot.json.tmp`, fsync, rename to `snapshot.json` (atomic publish).
6. Compute SHA-256 of the snapshot, take first 16 hex chars, write `manifest.json` per §5 the same way.

**Exit codes:**

- `0` — published a new snapshot successfully.
- `1` — fatal error; no snapshot written; previous file untouched. CI fails.
- `2` — partial success; snapshot written using "last good values" fallback per §7.4 because at least one source was entirely down. CI emits a warning annotation but does not fail.

**Logging:** structured JSON to stdout per §8.1. No use of stderr — Actions captures stdout cleanly into the run log. Don't pretty-print logs in production; one JSON object per line.

**Environment variables:** honour all of §9 (`DATA_DIR`, `LISTEN_PORT`, `UPDATE_TIME_UTC`, `ALL_TIME_START`, `YEAR_DAYS`, `PURGE_CACHE`, `LOG_LEVEL`, `HTTP_USER_AGENT`) where they make sense for a one-shot CLI. `LISTEN_PORT` and `UPDATE_TIME_UTC` are inert in this variant — the schedule lives in the workflow YAML.

---

## 5. The Actions workflows

### 5.1 `update-snapshot.yml` — the daily publisher

```yaml
name: Update snapshot

on:
  schedule:
    - cron: '0 2 * * *'        # 02:00 UTC daily, per §7.1
  workflow_dispatch:
    inputs:
      purge_cache:
        description: 'Purge cache and refetch everything'
        type: boolean
        default: false

permissions:
  contents: write              # commit cache + public back to the repo
  pages: write                 # deploy to Pages
  id-token: write              # required by deploy-pages

concurrency:
  group: update-snapshot
  cancel-in-progress: false    # never let two runs write the cache concurrently

jobs:
  update:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'

      - name: Build CLI
        run: dotnet publish src/NationalGridLive.Updater -c Release -o ./bin

      - name: Generate snapshot
        id: gen
        env:
          HTTP_USER_AGENT: "national-grid-live-tools/1.0 (+https://github.com/${{ github.repository }})"
        run: |
          ./bin/NationalGridLive.Updater generate-snapshot \
            --cache-dir ./cache \
            --out-dir ./public/v1 \
            ${{ inputs.purge_cache && '--purge-cache' || '' }}

      - name: Validate schema
        run: |
          jq -e '
            .schemaVersion == 1
            and (.generated | type == "string")
            and (.year.dates | length) > 0
            and (.year.price | length) == (.year.dates | length)
            and (.allTime.dates | length) > 0
          ' public/v1/snapshot.json
          jq -e '.etag and .sizeBytes and .generated' public/v1/manifest.json

      - name: Commit cache and public
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add cache public
          if git diff --cached --quiet; then
            echo "::notice::No changes to commit"
          else
            git commit -m "snapshot: $(date -u +%Y-%m-%d)"
            git push
          fi

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: ./public

      - name: Deploy to Pages
        uses: actions/deploy-pages@v4
```

**Notes for the implementer:**

- `concurrency.cancel-in-progress: false` is important: a `workflow_dispatch` rerun must queue, not interrupt, an in-flight scheduled run.
- The `jq` validation catches schema regressions before they reach the iOS app. Extend it as the schema grows.
- `permissions.contents: write` is required to commit the cache back; the default `GITHUB_TOKEN` is granted this when listed here explicitly.
- `timeout-minutes: 30` is well above the expected ~2-minute steady-state run and the ~10-minute initial-backfill worst case. Tune down later if desired.

### 5.2 `pr-validate.yml` — PR safety net

Same as `update-snapshot.yml` minus the commit and deploy steps. It builds, runs `dotnet test`, runs the CLI against a fixture cache, and runs the `jq` validation. Required for branch protection on `main`.

### 5.3 `staleness-check.yml` — the canary

Scheduled workflows can fail silently if every source is down for days running, the cron itself misfires, or a code bug stops the commit step. Detect this:

```yaml
name: Staleness check

on:
  schedule:
    - cron: '0 6 * * *'        # 4 hours after the daily update window

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Fail if snapshot is older than 48h
        run: |
          generated=$(jq -r .generated public/v1/manifest.json)
          age_hours=$(( ( $(date -u +%s) - $(date -u -d "$generated" +%s) ) / 3600 ))
          echo "Snapshot age: ${age_hours}h"
          if [ "$age_hours" -gt 48 ]; then
            echo "::error::Snapshot is $age_hours hours old — updater is failing"
            exit 1
          fi
```

Failed workflows trigger GitHub's default email notification to the repo owner. That is the alerting channel.

---

## 6. GitHub Pages setup

1. **Repo Settings → Pages → Source:** select **GitHub Actions** (not "Deploy from a branch").
2. **First deploy:** trigger `update-snapshot.yml` manually via the Actions tab → workflow_dispatch.
3. **Verify** the URLs in §3 above return 200 with `Content-Type: application/json`.
4. **Custom domain (optional):** add a `CNAME` file to `public/`. Pages handles TLS automatically.

`public/index.html` is a single-screen landing page containing:
- Project description (one paragraph).
- The three attribution strings from §3.1, §3.2, §3.3 of the original spec, verbatim.
- Links to `/v1/snapshot.json` and `/v1/manifest.json`.
- The `generated` timestamp from the manifest (server-side rendered at build time, or fetched client-side via a tiny inline script — implementer's choice).

This page is required because Pages serves the directory root; it also doubles as a public status page someone can eyeball.

---

## 7. Initial backfill

The very first run has to fetch ~12 years of data across three sources. Expected total: 5–10 minutes — within Actions limits but slow to debug if anything goes wrong. **Do the initial backfill locally:**

```
dotnet run --project src/NationalGridLive.Updater -- \
  generate-snapshot --cache-dir ./cache --out-dir ./public/v1
git add cache public
git commit -m "Initial backfill"
git push
```

After this, every Actions run only fetches one new day's worth of finalised data plus the current (uncached) day. Steady-state runs complete in well under two minutes.

---

## 8. Repo hygiene

- `cache/` is **committed**. Each file is a few KB; ~12 years × 3 sources × 365 ≈ 13k files, ~50–200 MB total. Comfortably inside the 1 GB Pages limit and the 5 GB recommended repo size.
- `.gitignore` excludes `bin/`, `obj/`, `*.tmp`. **Do not** exclude `cache/` or `public/` — they are the deployment artefacts.
- If repo size becomes a concern in future years, add an opt-in `--prune-old-cache` flag that drops daily cache files for months that are already finalised in `allTime` and are outside the rolling `year`. Do not prune automatically.

---

## 9. Testing

- **Unit tests** for each source client: mock the `HttpMessageHandler` and assert pagination boundaries (especially the 14-day window for Carbon Intensity), retry/backoff behaviour, and `null`-filling for pre-API-start dates per §3.4.
- **Aggregation tests**: golden inputs → golden daily/monthly means, including edge cases for missing intervals.
- **Integration test**: run `generate-snapshot` against `tests/fixtures/` (a checked-in mini-cache), compare resulting `snapshot.json` byte-for-byte to `tests/golden/snapshot.json` after canonical re-serialisation.
- **Schema test**: validate the golden snapshot against a JSON Schema derived from §4.1 of the original spec.

The PR validate workflow runs all of the above plus the production `jq` check from the update workflow.

---

## 10. Definition of done

A change is shippable when all of these hold:

1. `dotnet test` passes locally.
2. `dotnet run -- generate-snapshot --cache-dir ./cache --out-dir ./public/v1` produces files passing the `jq` schema check.
3. The `update-snapshot` workflow has succeeded at least once via `workflow_dispatch`.
4. `https://<user>.github.io/<repo>/v1/snapshot.json` returns **200**, `Content-Type: application/json`, gzip-encoded, conforming to §4.1.
5. `https://<user>.github.io/<repo>/v1/manifest.json` returns **200** conforming to §5.
6. `https://cdn.jsdelivr.net/gh/<user>/<repo>@main/public/v1/snapshot.json` also returns 200 (the optional CDN fallback the iOS app may use).
7. The `staleness-check` workflow has run at least once and passed.
8. `README.md` documents the manual-trigger flow and the local-dev flow.

---

## 11. Out of scope (this delta document)

- Changes to data sources, schemas, attribution, or aggregation logic. Those are governed solely by `SPECIFICATION.md`.
- iOS-side changes. The iOS app fetches the same `/v1/snapshot.json` URL regardless of how it is served.
- Migration back to a container. If that happens, this document is deleted and `SPECIFICATION.md` is again the single source of truth.

---

**See also:** [`SPECIFICATION.md`](./SPECIFICATION.md) — the behavioural contract.
