# ADR 0008: Consumer validation runs in disposable shared clones

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

OPS-01 needs each consumer built at an exact commit against a package candidate at an exact
commit, with the consumer's committed relative paths (`../../OpenCineUI`,
`../../../OpenCineUI/Android`) resolving to the candidate and never to a live sibling checkout.
Primary checkouts are shared (ADR 0005), so validation must not switch them or leave state in
them.

## Decision

- `atlas compat run` builds in a fresh `atlas-compat-*` folder in the system temp directory.
  The consumer and the package are cloned there as siblings under their registry `local_dir`
  with `git clone --shared --no-checkout` and `checkout --detach <commit>`. Shared clones read
  objects through alternates and write nothing to the source repository, so there is no
  `git worktree` metadata to add or prune. The folder is deleted afterwards, also on failure
  or interrupt.
- The candidate commit always replaces the consumer's own pin (`opencine-pins.txt`); the pin is
  recorded next to the tested commit. The consumer's CI checkout script is not used.
- A package path printed outside the workspace fails the check. Missing checkouts, commits,
  tools, `JAVA_HOME`/`ANDROID_HOME`, or a failed clone or patch are `unavailable`, never
  `passed`.
- The deliberate incompatible fixture for the gate is a patch passed to `--inject-break`. It is
  applied only inside the workspace, its result goes to a separate `.inject-break.json`, and the
  patch itself is not kept in any repository.
- Consumer builds need macOS, Xcode and the Android SDK, so `compat run` is a manual step on a
  developer Mac (or a later self-hosted macOS runner). Atlas CI runs only `compat plan`.

## Consequences

`tests/test_compat.py` checks that a run leaves the fixture checkouts byte-identical (including
`.git`), that the resolved package path is inside the workspace, that unavailable never passes,
and that the workspace is gone after a failure and after an interrupt. Gradle daemons started
by a run can outlive it; they hold no workspace state that later builds depend on.
