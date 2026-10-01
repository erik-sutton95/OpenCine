# ADR 0001: Local-only repositories until hosting is decided

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

Plan section 15.3 requires a hosting and ownership decision before any remote repository is
created. App pull requests whose package dependencies point at local paths cannot pass CI.

## Decision

No remote repository is created, nothing is pushed, no pull request is opened and nothing is
merged. New repositories (`opencapture-atlas`, `OpenCineUI`, `OpenCineCore`) are local Git
repositories in the shared workspace folder. App changes live on local branches in task
worktrees. [PUBLISH.md](../../PUBLISH.md) lists the exact steps to publish.

## Consequences

Registry entries for the new repositories record `repository.url: null` and status
`candidate` until published. No CI has run on any of this work.
