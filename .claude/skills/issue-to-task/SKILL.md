---
name: issue-to-task
description: Take an issue from any OpenCapture repository (OpenCine, OpenPocketCine, OpenInstaCine, OpenZCine) to a verified change in the repository that owns the fix. Use when asked to work on, fix or look into an issue number, or to pick the next issue.
---

# Issue to task

Run from the OpenCine checkout. `atlas` means `python3 atlas/tools/atlas.py`. Rules: `AGENTS.md`.

1. **Workspace.** `atlas ensure --check`; if a repository is missing, `atlas ensure` clones it
   next to OpenCine.
2. **Find the issue.** `atlas issues [repo]` lists open issues of every registered repository.
   Offline, or for text the user pasted, save it to a file (first line the title) and pass
   `--from-file <file>` to `task start`.
3. **Mode.** Investigate or plan: stop before creating worktrees. Implement: continue.
4. **Route before editing.** Note the platform (iOS, Android, both): Swift and Kotlin owners
   can differ, and some Android code is still app-owned. Find the code (`atlas/docs/ROUTING.md`,
   source search), then `atlas impact <symbol or path>`:
   - Declared in OpenCine and used by the app on that platform: shared. The fix goes to
     OpenCine; every app the output lists as linking the owner must still build and pass.
   - Declared only in the app: app-only.
   - Output says the app "declares its own" with the same logic: the app runs its copy, so fix
     the copy (or move the app onto the shared code as its own change). A same-named type that
     only carries data is not a copy.
   - A bug in a shipped build: also `atlas impact <symbol> --app-ref main`; `main` may still
     run code the next release replaced (`atlas/docs/ROUTING.md`, Shipped versus next release).
     Fix where the reporter's build runs (`--base main`) and write in `TASK.md` whether the next
     release needs the same fix, in the app or in OpenCine.
5. **Start.** `atlas task start <repo>#<n>` (app-only) or
   `atlas task start <repo>#<n> --with opencine` (shared; add `--with <app>` for each other app
   you will change or build against the change). Fill in its "Routing decision". It writes `<workspace>/OpenCine-tasks/<repo>-<n>/` with one
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
