---
name: issue-to-task
description: Take an issue from any OpenCapture repository (OpenCine, OpenPocketCine, OpenInstaCine, OpenZCine) to a verified change in the repository that owns the fix. Use when asked to work on, fix or look into an issue number, or to pick the next issue.
---

# Issue to task

Run from the OpenCine checkout. `atlas` means `python3 atlas/tools/atlas.py`. Rules: `AGENTS.md`.

1. **Workspace.** `atlas ensure --check`; if a repository is missing, `atlas ensure` clones it
   next to OpenCine.
2. **Find the issue.** `atlas issues [repo]` lists open issues of every registered repository.
   Offline it says so and lists nothing; ask the user for the issue text instead.
3. **Mode.** Investigate or plan: stop before creating worktrees. Implement: continue.
4. **Route before editing.** Read the issue, find the code (`atlas/docs/ROUTING.md`, source
   search), then `atlas impact <symbol or path>`:
   - Declared in OpenCine: shared. The fix goes to OpenCine, and every app the output lists as
     linking the owner gets verified.
   - Declared only in the app: app-only.
   - The app declares its own type with a shared type's name: a leftover copy. Fix the shared
     code; removing the copy is its own change.
5. **Start.** `atlas task start <repo>#<n>` (app-only) or
   `atlas task start <repo>#<n> --with opencine` (shared; repeat `--with <app>` for every
   linking app you will verify). It writes `<workspace>/OpenCine-tasks/<repo>-<n>/` with one
   worktree per repository and `TASK.md` (issue text, bases, instructions, gate). Apps in that
   folder build against the folder's `OpenCine`: the task branch for a shared fix, the app's pin
   otherwise. The base is the branch the app builds OpenCine on (today `opencine/integration`);
   `--base main` targets the shipping branch instead.
6. **Work** only in those worktrees, under each repository's own instructions (listed in
   `TASK.md`). Check the commit identity column before the first commit.
7. **Verify** (AGENTS.md, Verification): OpenCine checks for a shared change, then each linking
   app's checks in its task worktree. iOS tests on a private simulator. Operator-visible behavior
   on a physical device, or report it as `untested`.
8. **Commit** in each worktree with explicit paths (Conventional Commits). Push, pull request,
   merge and pin moves only when the user asked; a shared fix lands in OpenCine first, then
   each app moves its pin in its own change.
9. **Report** as `TASK.md` Handoff says. Clean up with the commands at its end once merged.
