# SwipeWise docs

Deep dives on how the app and its components work. Start with **Architecture** for the
big picture, then drill into whichever subsystem you need.

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | The mental model — app vs. catalog vs. classifier, the data files, and how a swipe becomes a recommendation |
| [sophtron.md](sophtron.md) | Bank sync: auth, connect/MFA (V2), FDX V3 reads, the mapper, stable IDs, the sync engine, sync state |
| [classifier-and-brands.md](classifier-and-brands.md) | `classifyLabel`, `brands.json`, the recognition cascade, brand_id vs. category |
| [reward-catalog.md](reward-catalog.md) | `catalog.json` → catalog tables → `CatalogSnapshot` → pure `RewardEngine` → `engine_ranker` |
| [nearby.md](nearby.md) | Nearby fetch (Google Places), tile cache, geofences, dwell notifications |
| [database.md](database.md) | Full SQLite schema reference |
| [setup.md](setup.md) | Keys, build flags, git hooks, local-data reset, troubleshooting |

## Hard-won knowledge — where each thing is written down

Things that cost real time to learn, and the file that owns each one. Add to the owning file, never
to a planning doc: planning docs get deleted.

| Topic | Home |
|---|---|
| Schema changes need `_onUpgrade`; never `ConflictAlgorithm.replace` on a parent table | [setup.md](setup.md), [database.md](database.md) |
| `flutter analyze` doesn't check Kotlin — `:app:lintDebug` after a `minSdk` change | [setup.md](setup.md) |
| Release builds serve a stale AOT snapshot | [setup.md](setup.md) |
| Off-screen tabs go stale (`IndexedStack`) | [architecture.md](architecture.md) |
| App Check cost (~2.2 s) and per-isolate state | [nearby.md](nearby.md) |
| Google place types are hierarchical, so `includedTypes` subtypes are redundant — and Places cost is a step function at every 50 types | [nearby.md](nearby.md) |
| FDX hard limits — no MCC, no lat/lng, no reward balances, no pending | [sophtron.md](sophtron.md) |

The backend engine that produces the catalog, and the API that serves it, each keep their own
equivalent index in their own repo.

Forward-looking design — what's planned but not built — is not tracked in this repo.
