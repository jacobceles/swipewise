# SwipeWise docs

Deep dives on how the app and its components work. Start with **Architecture** for the
big picture, then drill into whichever subsystem you need.

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | The mental model — app vs. catalog vs. classifier, the data files, and how a swipe becomes a recommendation |
| [sophtron.md](sophtron.md) | Bank sync: auth (HMAC), connect/MFA (V2), FDX V3 reads, the mapper, stable IDs, the sync engine, sync state |
| [classifier-and-brands.md](classifier-and-brands.md) | `classifyLabel`, `brands.json`, the recognition cascade, brand_id vs. category |
| [reward-catalog.md](reward-catalog.md) | `catalog-v{version}.json` → catalog tables → `CatalogSnapshot` → pure `RewardEngine` → `engine_ranker` |
| [nearby.md](nearby.md) | Nearby fetch (Google Places), tile cache, geofences, dwell notifications |
| [database.md](database.md) | Full SQLite schema reference |
| [setup.md](setup.md) | Keys, build flags, git hooks, local-data reset, troubleshooting |

For **forward-looking** design (what's planned, not built) see [`../todo/`](../todo/):
the [card-rewards catalog](../todo/rewards_catalog.md) spec and the [roadmap](../todo/roadmap.md).
