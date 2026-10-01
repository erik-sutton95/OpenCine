# opencapture-atlas

Entry point for understanding and coordinating work across the OpenCapture camera apps
and the shared OpenCine packages. It holds a repository registry, routing notes, exact
source baselines, a typed dependency map and optional Graphify navigation snapshots.

It is **not** a build dependency of anything, not a container for app source, not a
superproject with submodules and not a release system. Apps build and release without it.

## Naming

`opencapture-atlas` is the portfolio workspace. The shared Swift/Android products keep
their `OpenCine...` names (`OpenCineCore`, `OpenCineUI`, ...). The two names describe
different responsibilities. Do not rename existing projects to match either one.

## Registered repositories

| Atlas ID | Status | Layer | Role |
|---|---|---|---|
| `openpocketcine` | active | app | DJI Osmo Pocket app; donor of UI 2.0 and Multi View |
| `openinstacine` | active | app | Insta360 Luna app; source-copy of the Pocket shell |
| `openzcine` | active | app | Nikon Z app; `main` plus the unmerged `feat/monitor-engine-port` candidate |
| `opencineui` | candidate | ui | Shared design system being extracted (UI-01/UI-02) |
| `opencinecore` | candidate | core | Shared contracts being defined (CORE-01) |
| `opencapture-atlas` | active | atlas | This repository (registered so nothing can depend on it) |

Registry entries live in `repos/<id>/meta.json` (authored facts, typed edges, pinned refs)
and `repos/<id>/SUMMARY.md` (a short map). Candidate entries and edges are never live
dependencies.

## Entry points

- Agents: [AGENTS.md](AGENTS.md), then [docs/ROUTING.md](docs/ROUTING.md).
- Multi-repo work: [docs/EXECUTION.md](docs/EXECUTION.md), task briefs in [docs/tasks/](docs/tasks/).
- Local paths and worktrees: [docs/LOCAL_CHECKOUTS.md](docs/LOCAL_CHECKOUTS.md).
- Keeping the atlas correct: [docs/MAINTENANCE.md](docs/MAINTENANCE.md).
- Contracts and decisions: [docs/CONTRACTS.md](docs/CONTRACTS.md), [docs/architecture/](docs/architecture/).
- Frozen baseline and donors: [docs/baseline/BASE-01.md](docs/baseline/BASE-01.md).
- Publishing this and the new repos: [docs/PUBLISH.md](docs/PUBLISH.md).

## Tool

`tools/atlas.py` is a Python 3 standard-library CLI. Every command except
`graph build`/`graph merge` is read-only.

```sh
python3 tools/atlas.py doctor              # registry, local paths, tooling, snapshots
python3 tools/atlas.py locate openzcine    # verified path, branch, commit, dirty, worktrees
python3 tools/atlas.py deps openinstacine  # typed edges with evidence
python3 tools/atlas.py impact openpocketcine
python3 tools/atlas.py stale
python3 tools/atlas.py check               # CI gate
python3 tools/atlas.py graph plan          # what a Graphify build would read and write
python3 -m unittest discover -s tests
```
