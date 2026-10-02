# ADR 0005: Shared checkouts are never switched

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

The Pocket primary checkout is used live by other sessions; the Nikon primary checkout holds
uncommitted user spike work on another branch.

## Decision

Primary checkouts are read only through Git objects (`git show <sha>:<path>`, `ls-tree`,
`archive`). Edits happen only in task-owned worktrees created from an explicit base. Atlas
commands never write to a checkout; their reads disable optional Git locks so even
`git status` does not refresh a shared index.

## Consequences

`tests/test_readonly.py` hashes the atlas and every fixture checkout (including `.git`)
around each read-only command.
