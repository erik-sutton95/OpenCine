# ADR 0003: BASE-01 source baselines

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Decision

| Repo | Ref | Commit |
|---|---|---|
| `openpocketcine` | `origin/main` | `27b15028e86d93798c802ddb56c7c474a30bb4c7` (includes the vertical-raster fix as #482) |
| `openinstacine` | `main` = `origin/main` | `35b6f33b20cbd791a4c24b6380046f180f1ee454` (last Pocket sync `9e306c91`) |
| `openzcine` | `origin/main` | `9ac413876ddc663e95edb6cf7913f2aa73ea03b3` |
| `openzcine` candidate | `feat/monitor-engine-port` | `ef38a2646e49c248c089d6bf5d7bfca1c836dd62` (not merged) |

These are the `refs` in `repos/<id>/meta.json`. Evidence: [BASE-01.md](../../baseline/BASE-01.md).

## Consequences

When a source advances, `tools/atlas.py stale` reports the pin as outdated; moving a pin is
a reviewed registry change, not an automatic refresh.
