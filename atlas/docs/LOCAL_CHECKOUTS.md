# Local checkouts and worktrees

Shared registry files never contain machine paths. Each machine keeps its own mapping in
the ignored file `.local/checkouts.json`, copied from
[`checkouts.example.json`](../checkouts.example.json). `python3 tools/atlas.py check` fails
if a tracked file contains a private absolute path.

## Resolution

One resolver (`tools/resolver.py`) serves every command:

1. An explicit `repos.<id>` path in `.local/checkouts.json` wins. If that path is missing
   the repo is reported **missing**; the resolver does not silently fall back.
2. Otherwise it looks for `<workspace>/<local_dir>` in each of: `workspace` from the
   config, the `OPENCAPTURE_WORKSPACE` environment variable, the folder that contains the
   OpenCine checkout this atlas lives in (`<workspace>/OpenCine/atlas`), and the atlas
   folder's own parent. More than one distinct checkout is **ambiguous**: add an explicit
   mapping.
3. A candidate must be the top level of a Git checkout (a primary clone with a `.git`
   directory or a linked worktree with a `.git` file) and, when the registry records a
   canonical URL, one of its remotes must match it. Symlinked paths and paths with spaces
   are resolved to their real location first.

`python3 tools/atlas.py locate <id>` prints the verified path, current branch, commit,
dirty state and every linked worktree with its branch. Use `--json` for scripts.

`python3 tools/atlas.py ensure --check` runs the same resolution for every registered repository
and reports what is missing; `ensure` clones a missing one from its registered URL into its
explicit mapping or `<workspace>/<local_dir>`, never over an existing folder. With an `identity`
(`name`, `email`) in `.local/checkouts.json` it sets that identity in each new clone, and
`task start` warns when a task worktree would commit as someone else.

## Worktree model

- Primary checkouts are shared. Other sessions and the user may be working in them, with
  uncommitted changes on any branch. Never switch, reset, clean or pull them from a task.
- Read pinned sources with Git objects: `git -C <checkout> show <sha>:<path>`,
  `git -C <checkout> ls-tree -r <sha>`, or `git archive <sha>` into a temporary folder.
- Edit only in a task-owned worktree created from an explicit base, for example
  `git -C <checkout> worktree add -b <task-branch> <workspace>/<Repo>-worktrees/<task> origin/main`.
- A worktree's folder name is not branch evidence. `locate` reports the branch Git records.
- `python3 tools/atlas.py task start <repo>#<n> [--with <repo>]` creates the worktrees of an
  authorized implementation task in `<workspace>/OpenCine-tasks/<repo>-<n>/`, one per
  repository, named by `local_dir`, so an app's `../OpenCine` is the task's own OpenCine
  (the task branch with `--with opencine`, otherwise detached at the app's pin). Branch
  `issue/<repo>-<n>`; base: `--base`, else the ref the repository builds OpenCine on (its
  registry edge), else its baseline. It never commits, pushes or deletes; `TASK.md` ends with
  cleanup commands. Other worktrees are created by hand as above.
- In Orca, opt into `task start ... --orca`: registered repository paths fill missing
  checkout mappings in memory, the same physical sibling worktrees are discovered/adopted
  through the public catalog, and identity/link/parent verification is recorded locally.
  No path moves, global visibility changes or extra agent launch occur. Linked central
  issues resolve the original app key and include editable Core and app. See
  [LINKED_ISSUES.md](LINKED_ISSUES.md) for conflict checks, partial recovery and Orca cleanup.

## Apple and Android local overrides

During candidate validation an app points at one sibling checkout of the platform by
relative path: SwiftPM `.package(path: "../OpenCine")`, XcodeGen `path: ../../OpenCine` (or
the Xcode project's local package reference), and one Gradle
`includeBuild("../../../OpenCine/Android")` named `opencine` that substitutes the
`com.opencapture.opencine:*` coordinates the app uses. `opencine-pins.txt` holds one line,
`OpenCine <sha>`. Those overrides belong on a task branch, never in a release configuration.
[PUBLISH.md](PUBLISH.md) describes the swap to URL plus version once the remote exists.
