# opencapture-atlas agent guide

The atlas routes and coordinates; product code lives in the registered repositories.
This is the only agent instruction file (`CLAUDE.md` just points here).

1. Record the requested mode: **investigate**, **plan** or **implement**. Investigate and
   plan stop before edits or worktree creation. A plan or issue text never authorizes
   merges, releases, publishing or remote repository creation.
2. Route with [docs/ROUTING.md](docs/ROUTING.md) and the relevant `repos/<id>/SUMMARY.md`,
   then confirm ownership in the target repo's current source and manifests.
3. Resolve sources with `python3 tools/atlas.py locate <id>`. Report branch, commit, dirty
   state and worktrees. The atlas checkout is never the target app's checkout.
4. Primary checkouts are shared and may hold someone else's dirty work. Read them through
   Git objects (`git -C <checkout> show <sha>:<path>`). Edit only in a task-owned worktree,
   and load the target repo's own instructions there.
5. Evidence order: pinned source and manifests, then exercised tests and hardware
   evidence, then source docs, then this atlas, then Graphify output. A graph edge is a
   search hint, never proof.
6. Keep status words honest: implemented, automated checks passed, hardware-qualified,
   candidate, integrated, released, unsupported, untested. Missing evidence stays untested.

Multi-repo implementation follows [docs/EXECUTION.md](docs/EXECUTION.md). Before changing
atlas files, read [docs/MAINTENANCE.md](docs/MAINTENANCE.md) and run
`python3 tools/atlas.py check`. Machine paths and task notes go in ignored `.local/`.
Never use the em dash character in atlas text.
