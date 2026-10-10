# <WORK-PACKAGE-ID>: <concrete outcome>

Status: proposed / in progress / ready for review / integrated
Requested scope: <what the user authorized: investigate, plan or implement; never merge,
publish or release unless stated>

## Source baseline

- Repo ID, canonical remote, exact source SHA/ref (`python3 tools/atlas.py locate <id>`).
- Worktree path (in ignored `.local/` notes, not here) and initial dirty state.
- Relevant plan sections and current source-owned instructions.
- Candidate dependencies and consumer revisions (`compat/candidates.json`).

## Ownership

- Agent owns: <specific files/modules>.
- Other agents own: <adjacent files/modules>.
- Coordination seam: <interface or schema being changed, and its single owner>.

## Implementation

1. <bounded action with expected result>
2. <bounded action with expected result>

## Completion gate

- <observable behavior or invariant>
- <required automated checks, run from the target repo's own instructions>
- <physical qualification, or explicit `untested`>
- <consumer compatibility and persistence check>

## Rollback

- <previous compatible pin/path and data considerations>

## Handoff

- Commits/patches produced.
- Tests actually run and results.
- Remaining work and evidence gaps.
- Dependency/release order; no implied merge/publication.
