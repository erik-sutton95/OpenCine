# OpenCine atlas

Entry point for understanding and coordinating work across the OpenCapture camera apps and the
shared OpenCine platform. It holds a repository registry, routing notes, exact source baselines,
a typed dependency map with per-target product layers, compatibility records and optional
Graphify navigation snapshots. It lives inside the OpenCine repository at `atlas/` (formerly the
separate `opencapture-atlas`, ADR 0010).

It is **not** a build dependency of anything, not a container for app source and not a release
system. Apps build and release without it; no target or module may build against it.

## Naming

OpenCapture is the portfolio; OpenCine is the shared platform repository and its products keep
their names (`OpenCineCore`, `MonitorUI`, ...). Do not rename existing projects to match either.

## Registered repositories

| Atlas ID | Status | Layer | Role |
|---|---|---|---|
| `openpocketcine` | active | app | DJI Osmo Pocket app; donor of UI 2.0 and Multi View |
| `openinstacine` | active | app | Insta360 Luna app; source-copy of the Pocket shell |
| `openzcine` | active | app | Nikon Z app; `main` plus the unmerged `feat/monitor-engine-port` candidate |
| `opencine` | candidate | platform | Every shared product (core, ui, multicam, vendor and harness layers per target) and this atlas |

Registry entries live in `repos/<id>/meta.json` (authored facts, typed edges, pinned refs, and
for `opencine` the layer of every target and Gradle module) and `repos/<id>/SUMMARY.md` (a short
map). Candidate entries and edges are never live dependencies.

## Entry points

- Agents: the repository's [AGENTS.md](../AGENTS.md), then [docs/ROUTING.md](docs/ROUTING.md).
- Multi-repo work: [docs/EXECUTION.md](docs/EXECUTION.md), task briefs in [docs/tasks/](docs/tasks/).
- Local paths and worktrees: [docs/LOCAL_CHECKOUTS.md](docs/LOCAL_CHECKOUTS.md).
- Keeping the atlas correct: [docs/MAINTENANCE.md](docs/MAINTENANCE.md).
- Contracts and decisions: [docs/CONTRACTS.md](docs/CONTRACTS.md), [docs/architecture/](docs/architecture/).
- Frozen baseline and donors: [docs/baseline/BASE-01.md](docs/baseline/BASE-01.md).
- Publishing OpenCine and moving the apps onto it (one resumable command, `tools/publish.py`): [docs/PUBLISH.md](docs/PUBLISH.md).
- Versions, version policy and app pins: [compat/VERSIONS.md](compat/VERSIONS.md).
- Consumer revision sets for platform candidates: [compat/candidates.json](compat/candidates.json) (older records: [compat/archive/](compat/archive/)).
- Navigation evaluation cases: [evals/navigation/](evals/navigation/).

## Tool

`tools/atlas.py` is a Python 3 standard-library CLI. Every command except
`graph build`/`graph merge` and `compat run` is read-only. Run it from this folder as below, or
from the repository root with an `atlas/` prefix (`python3 atlas/tools/atlas.py check`, as CI does).

```sh
python3 tools/atlas.py doctor              # registry, local paths, tooling, snapshots
python3 tools/atlas.py locate openzcine    # verified path, branch, commit, dirty, worktrees
python3 tools/atlas.py deps openinstacine  # typed edges with evidence
python3 tools/atlas.py impact openpocketcine
python3 tools/atlas.py stale
python3 tools/atlas.py check               # CI gate (includes per-target layers of the enclosing OpenCine tree)
python3 tools/atlas.py graph plan          # what a Graphify build would read and write
python3 tools/atlas.py compat plan         # candidate consumer matrix (read-only)
python3 tools/atlas.py compat run <id>     # build consumers against a candidate (macOS, docs/EXECUTION.md)
python3 tools/publish.py                   # publish plan, dry run (docs/PUBLISH.md); --execute acts
python3 tools/rehearse_publish.py          # the whole publish against file:// remotes on disposable clones
python3 -m unittest discover -s tests
```
