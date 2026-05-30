# National Grid Live — Backfill snapshot service

Generates and hosts the **historical** grid data (Past Year / All Time) for the
[National Grid: Live](https://grid.iamkate.com/)-style iOS app. The app fetches
*live* data (last 24 h) directly from the public APIs; it can't fetch years of
history on-device (the APIs paginate in small windows — Carbon Intensity caps at
14 days), so this service pre-aggregates it into a single `snapshot.json` served
over GitHub Pages.

See [`SPECIFICATION.md`](SPECIFICATION.md) for the full design.

## How it works

A Swift CLI (`national grid live tools/main.swift`) aggregates the open APIs and
writes the snapshot. It runs **incrementally** on GitHub Actions:

```
        ┌─────────── daily GitHub Action (cron 04:00 UTC) ───────────┐
        │  fetch yesterday  →  append data/daily.csv                  │
        │  (Elexon FUELINST, NESO embedded, Carbon Intensity, price)  │
        │  roll up completed month  →  data/monthly.csv               │
        │  rebuild  →  public/v1/snapshot.json + manifest.json        │
        └──────────────┬───────────────────────┬─────────────────────┘
            commit data/ back to repo     deploy public/ to Pages
```

Because each run fetches only the new day(s), a daily run is seconds and a couple
of MB — not a full re-fetch. The accumulating `data/*.csv` is the source of truth;
`public/v1/` is the published output.

### Data model (matches the app + grid.iamkate.com)
- **Firm fuels + interconnectors** from Elexon **FUELINST** (absolute GW): gas = CCGT+OCGT+OIL, coal, nuclear, biomass, hydro = NPSHYD, pumped = PS; France = IFA+IFA2+ELECLINK, etc.
- **wind = FUELINST transmission wind + NESO embedded wind**; **solar = NESO embedded solar** (FUELINST has no solar). Embedded comes from NESO "Historic Demand Data {year}".
- **emissions** = Carbon Intensity `/intensity`; **price** = Elexon `market-index`.
- `generation = Σ fuels`, `transfers = Σ interconnectors`, `demand = generation + transfers`.

### Accuracy vs grid.iamkate.com
**Past year matches closely** (verified): generation 27.7 vs 27.7, demand 30.5 vs 30.7, gas 8.8 vs 8.2, wind 10.4 vs 10.9, solar 1.9 vs 2.1, price £81 vs £80, interconnectors within ~0.1.
**All Time can't fully match**: Carbon Intensity starts 2018-05 and FUELINST ~2018, but Kate's all-time spans 2012+, so the high-coal early years are missing (our all-time coal ≈0.5 vs 4.13). It's real data from 2018 onward — a hard API limit, not a bug.

## Granularity & file size

Hosted size is driven by point count (~290 B/point raw; **Pages auto-gzips**):

| Section   | Granularity        | Points | Raw    | Gzipped |
|-----------|--------------------|-------:|-------:|--------:|
| `year`    | **daily**          | 365    | ~55 KB | ~10 KB  |
| `allTime` | **monthly** (2018→)| ~96    | ~27 KB | ~4 KB   |
| (avoid)   | all-time *daily*   | ~5,100 | ~1.4 MB| ~240 KB |

`year` = daily and `allTime` = monthly keep the whole file ~25 KB over the wire.
`day`/`week` are **not** hosted — the app fetches those live.

## One-time setup

1. **Make the repo public** (free Pages + free Actions minutes).
2. **Settings → Pages → Source: GitHub Actions**.
3. **Seed the history**: Actions → *Backfill snapshot* → *Run workflow* → `mode: bootstrap`
   (this one run is heavier — it fetches ~1 year of days + monthly samples back to 2018).
4. After that the daily `cron` keeps it current automatically.

Published URLs (replace `OWNER`/`REPO`):
- `https://OWNER.github.io/REPO/v1/snapshot.json`
- `https://OWNER.github.io/REPO/v1/manifest.json` (cheap freshness check)

## Wiring the app

In `AppConfig.swift`:

```swift
static let `default` = AppConfig(
    live: .real,
    snapshot: .url(URL(string: "https://OWNER.github.io/REPO/v1/snapshot.json")!),
    refreshInterval: .seconds(300)
)
```

The app already has `URLSessionSnapshotProvider` (conditional GET via `ETag` →
304 when unchanged) and `CachingSnapshotProvider` (last-known-good offline). HTTPS
means no App Transport Security exception is needed.

## Local usage

```bash
# Daily append (default):
swift "national grid live tools/main.swift"

# One-time bootstrap (full daily year + monthly all-time):
MODE=bootstrap STEP_DAYS=1 ALLTIME=1 swift "national grid live tools/main.swift"

# Faster sparse year seed for testing:
MODE=bootstrap STEP_DAYS=5 ALLTIME=0 swift "national grid live tools/main.swift"
```

Env: `MODE` (`daily`|`bootstrap`), `DATA_DIR` (default `data`), `OUT_DIR`
(default `public/v1`), `STEP_DAYS`/`ALLTIME` (bootstrap), `MAX_CATCHUP` (daily,
default 14). HTTP responses are cached under `/tmp/nglsim/bf-cache` for fast
local re-runs.

## Repo layout

```
national grid live tools/main.swift   the generator
data/daily.csv, data/monthly.csv      persistent aggregates (committed by CI)
public/v1/snapshot.json, manifest.json published output (deployed to Pages)
.github/workflows/backfill.yml        the daily + bootstrap workflow
SPECIFICATION.md                      full service spec
```

All data © their providers — Elexon (BMRS), National Grid ESO & University of
Oxford (Carbon Intensity, CC BY 4.0), NESO (Open Licence).
