# Executing work across repositories

Use this after routing has found the owner, when a task will plan or change more than the
atlas. The atlas coordinates; it grants no permissions. Merging, tagging, publishing,
creating remotes and releasing each need their own explicit authorization.

## 1. Start

State, in the first task update:

- Requested mode: investigate, plan, or implement. Plan and investigate stop before edits or
  worktree creation.
- Work-package ID from [platform-plan.md](architecture/platform-plan.md) and the intended
  observable result.
- Source revisions from `python3 tools/atlas.py locate <id>` for every repository involved:
  path, branch, commit, dirty state. Say which worktree will receive edits.
- Any discrepancy between the plan's baseline and current source.

## 2. Confirm ownership and impact

1. Confirm the owner in current source and manifests (`atlas deps <id>`), not from the
   summary alone.
   Shared code has one owner repository, `opencine`; its `layers` say which product area a
   target belongs to, and `atlas check` holds every target and Gradle module to the plan's
   direction rules.
2. For a boundary change, run `atlas impact <owner> --include-candidates` for the repository
   order and `atlas impact <symbol or path>` for the owning target, the apps whose manifests link
   it and their call sites. Then refine against real source: repositories that need edits, generated outputs, consumers that only need
   validation, and unaffected repositories. Treat `INCOMPLETE` as unknown, never as "no
   consumers".

## 3. Prepare isolated worktrees (implement mode only)

- From an issue: `python3 tools/atlas.py task start <repo>#<n> [--with opencine] [--with <app>]`
  creates one worktree per repository in one task folder and writes `TASK.md` there (issue text,
  bases, instructions, identity, gate, cleanup). See [LOCAL_CHECKOUTS.md](LOCAL_CHECKOUTS.md).
- Otherwise one task-owned worktree per edited repository, from an explicit base:
  `git -C <checkout> worktree add -b <task-branch> <workspace>/<Repo>-worktrees/<task> <base>`.
- Never switch, reset, clean, pull or stash a primary checkout or another agent's worktree.
- Load the target repository's own instructions (`AGENTS.md`, `CLAUDE.md`, `README.md`) inside
  the worktree. They own build and test commands.
- Machine paths and worktree handles go in `.local/` task notes, never in tracked atlas files.

## 4. Write one brief per repository

Copy [tasks/TEMPLATE.md](tasks/TEMPLATE.md). A brief must let an agent that never read the atlas
do the work: exact base SHA and worktree, owned files, the seam being changed and who owns it,
dependency order, acceptance checks, hardware gate or explicit `untested`, rollback, and what
the handoff must report. When several agents work at once, give each disjoint files and name
one owner for any shared interface; others implement against it and report needed changes.

## 5. Validate against one revision set

Validate package candidates and each consumer against the same explicit revisions. Record
them in `compat/candidates.json`: package SHA, consumer SHAs, platforms, commands run and
results, then run them with `atlas compat run` ([below](#candidate-consumer-validation-ops-01)).
Statuses are `passed`, `failed`, `not-run`, `not-applicable` and `unavailable`; the last three
never count as passed. A package test passing does not mean an app builds; a compiled
instrumentation APK is not a hardware run.

## 6. Report and stop

Report the commits produced, checks actually run with results, missing hardware evidence, the
consumer matrix, and the dependency and release order. An opened pull request is not a merge;
a merge is not a release. Update atlas facts (edges, refs, `source-copy` removal) only after an
authorized merge changes reality.

## Candidate consumer validation (OPS-01)

`compat/candidates.json` lists each package candidate (repo and exact commit) and the consumers
it must not break (repo, ref, exact commit, checks). `atlas compat` turns that into a repeatable
producer-to-consumer check (plan 11.5).

```sh
python3 tools/atlas.py compat plan [<candidate>]          # read-only: layout, what would run
JAVA_HOME=<jdk> ANDROID_HOME=<sdk> \
python3 tools/atlas.py compat run <candidate> [--consumer <repo>] [--timeout <s>]
python3 tools/atlas.py compat run <candidate> --consumer <repo> --inject-break <patch>
```

What `run` does, per consumer:

1. Resolves the consumer and the package to their registered local checkouts and requires the
   exact recorded commits to exist there. If not: every check is `unavailable`.
2. Creates `atlas-compat-*` in the system temp folder and clones both into it with
   `git clone --shared --no-checkout` plus `checkout --detach <commit>`, each under its
   registry `local_dir`. The consumer's committed relative paths (`../../OpenCine`,
   `../../../OpenCine/Android`) therefore resolve inside the workspace, never to a live
   checkout. Shared clones read objects through alternates and write nothing to the source
   checkouts: no branch switch, no worktree metadata.
3. Runs the checks in order at the consumer root with `$ATLAS_COMPAT_WORKSPACE` and
   `$ATLAS_COMPAT_PACKAGE_COMMIT` set. Recipes keep build output inside the workspace (iOS uses
   `-derivedDataPath "$ATLAS_COMPAT_WORKSPACE/DerivedData"`). Check kinds:
   - `recipe`: exit 0 passes. `expect` regexes must appear in the output. With
     `resolves_package`, the output must name the package by an absolute path inside the
     workspace (Xcode's `Resolved source packages`, Gradle's `projectDir`). In every check, a
     package path outside the workspace is a failure.
   - `fingerprint`: the command's output must change after a one-byte edit to a package file
     (restored afterwards). Used for each app's build identity.
   - `native_outputs`: the fresh workspace must hold no `.so`, `.a` or `.dylib` before the
     checks, and every matching staged library must have been written by this run.
   - no runnable key: the recorded status and reason are kept (`not-applicable` needs a reason).

   A consumer may name a `pin_file` (`<Name> <sha>` lines, such as `opencine-pins.txt`). The
   run records the consumer's pinned package commit as `pinned_package_commit` next to the
   tested candidate commit; the workspace always holds the candidate, so a pass with a newer
   candidate is the evidence for bumping that pin. The consumer's own CI checkout script is
   not used.
4. Deletes the workspace, also on failure or interrupt, and records whether it is gone.

Results: statuses go back into `compat/candidates.json`; `compat/results/<candidate>.json`
holds the last run (exact package and consumer SHAs, toolchain versions, Gradle wrapper,
per-check exit code, duration, sanitized 30-line log tail and the first compiler errors of a
failed check). With `--consumer`, only that consumer's record is replaced; the other consumers keep
their last results (each record carries its own `finished_at` and toolchain). Full logs stay in ignored
`.local/compat-logs/`. Exit code: 0 all run checks passed, 1 something failed, 3 something
was unavailable.

| Status | Meaning |
|---|---|
| `passed` | Ran against the exact recorded commits and met every condition. |
| `failed` | Ran and did not succeed: non-zero exit, timeout, missing expected output, package resolved outside the workspace, unchanged fingerprint, stale or prebuilt native binary. |
| `unavailable` | Could not check: checkout or commit missing, tool or `JAVA_HOME`/`ANDROID_HOME` missing, clone/checkout/patch failure. Never a pass. |
| `not-applicable` | Intentionally not checked, with a recorded reason. |
| `not-run` | Not executed yet (or a native output was never produced because its build did not run). |

**Gate proof (`--inject-break`).** The patch is applied to the package clone inside the
workspace only. The run writes `compat/results/<candidate>.inject-break.json` (patch name, hash
and touched files) and never changes recorded statuses. Keep the patch out of every repository;
it exists only for the proof.

**What a pass means:** the consumer at that exact commit builds and tests against the package at
that exact commit through the consumer's own committed dependency wiring, with no live sibling
checkout and no cached native binary involved. **What it does not mean:** a released or
published package (local path resolution bypasses version constraints; the release-resolution
path is tested only after tagging, see [PUBLISH.md](PUBLISH.md)); hardware qualification; a
run of instrumentation tests; that a newer ref tip passes (`compat plan` shows when a ref moved);
or anything about consumers recorded as `not-run`.

**Where it runs.** Consumer builds need macOS with Xcode, `xcodegen`, `just`, the Swift Android
SDK and an Android SDK, so `compat run` is a manual step on a developer Mac or a self-hosted
macOS runner. Atlas CI runs only `compat plan` (read-only; every check shows `unavailable` there
because no checkouts exist). Existing required check names are unchanged.

Decision record: [ADR 0008](architecture/decisions/0008-compat-runs-in-disposable-shared-clones.md).

## Dry runs

Two complete dry-run briefs exercise this workflow without changing any app:

- [tasks/DRY-RUN-UI-scroll-fade.md](tasks/DRY-RUN-UI-scroll-fade.md): one shared UI change
  reaching three apps.
- [tasks/DRY-RUN-CAP-white-balance-pending.md](tasks/DRY-RUN-CAP-white-balance-pending.md): one
  capability change spanning two integrations.
