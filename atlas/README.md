# OpenCine atlas

Entry point for understanding and coordinating work across the OpenCapture camera apps and the
shared OpenCine platform. It holds a repository registry, routing notes, exact source baselines,
a typed dependency map with per-target product layers and compatibility records. It lives inside the OpenCine repository at `atlas/` (formerly the
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
- Linked app issues, reconciliation activation and Orca task adoption: [docs/LINKED_ISSUES.md](docs/LINKED_ISSUES.md).
- Contracts and decisions: [docs/CONTRACTS.md](docs/CONTRACTS.md), [docs/architecture/](docs/architecture/).
- Frozen baseline and donors: [docs/baseline/BASE-01.md](docs/baseline/BASE-01.md).
- Publishing OpenCine and moving the apps onto it (one resumable command, `tools/publish.py`): [docs/PUBLISH.md](docs/PUBLISH.md).
- Versions, version policy and app pins: [compat/VERSIONS.md](compat/VERSIONS.md).
- Consumer revision sets for platform candidates: [compat/candidates.json](compat/candidates.json) (older records: [compat/archive/](compat/archive/)).
- Navigation evaluation cases: [evals/navigation/](evals/navigation/).

## Tool

`tools/atlas.py` is a Python 3 standard-library CLI. Every command except `ensure` (clones
missing checkouts), `task start` (task worktrees and a brief), `new-app` (a new app folder),
`dupes --write-baseline`, `api --write` (rewrites `api/swift`), `consumers --write` (rewrites
`consumers/`) and `compat run` is read-only. Run it from this folder as below, or
from the repository root with an `atlas/` prefix (`python3 atlas/tools/atlas.py check`, as CI does).

```sh
python3 tools/atlas.py ensure --check      # every registered checkout present? (`ensure` clones missing ones)
python3 tools/atlas.py issues              # open issues of every registered GitHub repository (gh)
python3 tools/atlas.py impact MonitorTheme # owner, apps that link it, call sites (also a path)
python3 tools/atlas.py task start openpocketcine#12 [--with opencine]   # task folder + TASK.md
python3 tools/atlas.py task start opencine#70 --orca                   # resolve tracker, adopt physical sibling tasks in Orca
python3 tools/linked_issues.py                                        # read-only linked issue plan; --execute needs authority
python3 tools/atlas.py consumers MonitorTheme  # apps that adopt a symbol, module (OpenCineCore, :core) or path, and where
python3 tools/atlas.py consumers --write   # regenerate consumers/<app>.{md,json} at each app's ref tip (--check in CI)
python3 tools/atlas.py pins                # each app's OpenCine pin, commits behind, changed public API it uses
python3 tools/mcp_server.py                # the same as read-only MCP tools over stdio (registered in ../.mcp.json)
python3 tools/atlas.py api OpenCineCore --grep Camera  # public API snapshot of one module (Swift or :gradle)
python3 tools/atlas.py api --check --build # Swift snapshots versus an iOS Simulator build (CI); --write records them
python3 tools/atlas.py dupes --top 3       # duplicated code per repository pair vs compat/dupes-baseline.json
python3 tools/atlas.py dupes --candidate opencine-thin-app  # apps at a candidate's consumer commits
python3 tools/atlas.py new-app OpenFooCine  # a thin app next to OpenCine from templates/app (below)
python3 tools/atlas.py doctor              # registry, local paths, tooling
python3 tools/atlas.py locate openzcine    # verified path, branch, commit, dirty, worktrees
python3 tools/atlas.py deps openinstacine  # typed edges with evidence
python3 tools/atlas.py impact openpocketcine
python3 tools/atlas.py stale
python3 tools/atlas.py check               # CI gate (includes per-target layers of the enclosing OpenCine tree)
python3 tools/atlas.py compat plan         # candidate consumer matrix (read-only)
python3 tools/atlas.py compat run <id>     # build consumers against a candidate (macOS, docs/EXECUTION.md)
python3 tools/publish.py                   # publish plan, dry run (docs/PUBLISH.md); --execute acts
python3 tools/rehearse_publish.py          # the whole publish against file:// remotes on disposable clones
python3 -m unittest discover -s tests
```

## New-app template

`atlas new-app <Name> [--id <bundle id>] [--dest <folder>]` (SHELL-05) writes a thin app next to
this OpenCine checkout from [templates/app](templates/app) and touches nothing else:

- `ios/project.yml` (XcodeGen) and `Android/` (Gradle, OpenCine's version catalog and an
  `includeBuild` of `../OpenCine/Android`): `App.swift` / `MainActivity.kt` compose `AppShell`
  with the brand (`ShellBrand`), the integration list and the monitor and cover slots.
- Two variants. The shipping one (`<Name>` target, `camera` flavor) lists the app's integrations
  and starts empty. The SIMULATED one (`<Name>Simulated`, `simulated` flavor) lists OpenCine's
  `FakeIntegration` from its test support, so the shell runs and the contract test
  (`ShellContract`, `ShellContractTest`) passes without hardware. It is developer-only: the
  release workflow builds neither, and the `simulated` flavor has no release build.
- Entitlements, `opencine-pins.txt` (this checkout's commit), `scripts/checkout-opencine.sh`,
  tester notes (`ios/TestFlight/`, `Android/Play/`), `.github/workflows/ci.yml` and a manual
  `release.yml` (unsigned shipping builds; signing and upload are the app's).

`--integration` takes `fake` only: the DJI, Nikon and Luna integrations still need a connect port
that lives in their apps, so a real one is listed by hand (the generated README says where).
Template files end in `.tmpl` so no build or `atlas dupes` reads them as code; placeholders are
`__NAME__`, `__APP_ID__`, `__PACKAGE_PATH__` and `__OPENCINE_SHA__`.

Checks: `tests/test_newapp.py` generates an app into a temporary folder and checks its structure,
that the fake stays in the SIMULATED variants and that no file or function matches OpenCine's
(`atlas dupes --app <folder>` reports the same for any app folder).
`scripts/template-app-check.sh [ios|android]` (repository root) generates one next to OpenCine,
builds both iOS targets, runs the contract test and a screenshot on a private simulator, then the
Android unit tests, lint and both assemblies; CI runs it on every change. After registering a new
app, continue with [AGENTS.md](../AGENTS.md#adding-an-app).
