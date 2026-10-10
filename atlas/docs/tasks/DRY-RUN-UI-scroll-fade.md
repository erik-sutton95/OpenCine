# DRY-RUN-UI: soften the scroll fade edge on every app

Status: proposed (**dry run**: a workflow exercise; no app was changed)
Requested scope: plan only. Exercises [EXECUTION.md](../EXECUTION.md) for one shared UI change.
No merge, tag, publication or release is authorized.

Illustrative request: "The fade at the edge of scrolling lists is too abrupt. Make it softer
everywhere."

## Source baseline

- Routing: [ROUTING.md](../ROUTING.md) row "scroll fade, page chrome": owner today is
  `openpocketcine`; destination `opencineui` is a candidate, not adopted on any baseline.
- `openpocketcine` `https://github.com/erik-sutton95/OpenPocketCine` @
  `27b15028e86d93798c802ddb56c7c474a30bb4c7` (`main`). Primary checkout is shared: edit in a new
  worktree only.
- Owning files: `Sources/MonitorUI/MonitorScrollFade.swift`,
  `Apps/Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/MonitorScrollFade.kt`.
- Impact (`python3 tools/atlas.py impact openpocketcine --include-candidates`, run 2026-10-01):
  - Wave 1: `openinstacine` [apple] and [android] via source-copy (live): re-sync, review,
    rebuild. `openzcine@feat/monitor-engine-port` via source-copy (candidate).
  - Wave 2: `opencineui` via source-copy (candidate).
  - No manifest-derived library consumers at the baselines.
- Insta's copies of both files are byte-identical to Pocket's (BASE-01 section 2), so its sync
  applies cleanly; Nikon engine-port's copies must be compared file by file.

## Ownership

- Agent A owns: the two `MonitorScrollFade` files in the Pocket task worktree, plus their tests.
- Agent B (after A's commit exists) owns: running Insta's `scripts/sync-openpocketcine.sh` in an
  Insta task worktree and reviewing the result.
- Nikon engine-port: report only. Its owner decides whether to re-vendor; the branch is not
  merged and is not edited by this task.
- Coordination seam: the public API of `MonitorScrollFade` stays unchanged (only the gradient
  stops change), so no consumer code changes.
- If UI-01/UI-02 has been adopted by then, the owner becomes `opencineui` and A works there
  instead; Pocket and Insta then take a pin bump, not a copy.

## Implementation

1. A: `git -C <pocket checkout> worktree add -b ui/softer-scroll-fade <workspace>/OpenPocketCine-worktrees/softer-scroll-fade 27b15028e86d93798c802ddb56c7c474a30bb4c7`.
   Change both files; keep Swift and Compose behavior equivalent.
2. A: run Pocket's own checks for the touched code (from its `AGENTS.md` and `justfile`:
   `just swift-test`, `just android-check`). Record exact commands and results.
3. B: in an Insta worktree from `35b6f33b20cbd791a4c24b6380046f180f1ee454`, run
   `OPENPOCKETCINE_PATH=<pocket checkout> NEW_COMMIT=<A's commit> scripts/sync-openpocketcine.sh --dry-run`
   (the script defaults to `../OpenPocketCine`, which a worktree folder does not have), then the
   real sync. The
   Android copy is not covered by the script: copy `MonitorScrollFade.kt` by hand and record
   the donor SHA.
4. B: run Insta's checks (`just core-test`, `just android-check`).

## Completion gate

- Same gradient on iOS and Android in each app; no layout change.
- Pocket and Insta automated checks pass at the recorded revisions.
- Screenshots before and after on one iPhone and one Android device per app: **untested**
  until run on devices.
- Nikon engine-port: listed as an unvalidated candidate consumer, not silently skipped.

## Rollback

- Revert A's commit; Insta re-syncs to the previous donor SHA. No persisted data involved.

## Handoff

- Two branch commits (Pocket, Insta), never merged by the agents.
- Order: Pocket first, then Insta re-sync from Pocket's merged commit. Insta's sync must point
  at a commit that is actually on Pocket `main` before Insta merges.
- Atlas: after both merge, bump `refs` in `repos/openpocketcine/meta.json` and
  `repos/openinstacine/meta.json`, and the Insta `source-copy` `donor_revision`.

## What the dry run showed

- Owner, target refs and consumer order came from `atlas locate` and `atlas impact` without
  touching any checkout.
- The Insta Android copy has no sync mechanism; every shared Compose fix needs a manual copy
  until UI-02 lands. That is recorded as a separate `source-copy` edge with mechanism
  "manual copy".
