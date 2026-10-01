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
2. For a boundary change, run `atlas impact <owner> --include-candidates`. Then refine against
   real source: repositories that need edits, generated outputs, consumers that only need
   validation, and unaffected repositories. Treat `INCOMPLETE` as unknown, never as "no
   consumers".

## 3. Prepare isolated worktrees (implement mode only)

- One task-owned worktree per edited repository, from an explicit base:
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
results. Statuses are `passed`, `failed`, `not-run`, `not-applicable` and `unavailable`;
the last three never count as passed. A package test passing does not mean an app builds; a
compiled instrumentation APK is not a hardware run.

## 6. Report and stop

Report the commits produced, checks actually run with results, missing hardware evidence, the
consumer matrix, and the dependency and release order. An opened pull request is not a merge;
a merge is not a release. Update atlas facts (edges, refs, `source-copy` removal) only after an
authorized merge changes reality.

## Dry runs

Two complete dry-run briefs exercise this workflow without changing any app:

- [tasks/DRY-RUN-UI-scroll-fade.md](tasks/DRY-RUN-UI-scroll-fade.md): one shared UI change
  reaching three apps.
- [tasks/DRY-RUN-CAP-white-balance-pending.md](tasks/DRY-RUN-CAP-white-balance-pending.md): one
  capability change spanning two integrations.
