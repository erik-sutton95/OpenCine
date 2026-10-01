# ADR 0004: Shared theme takes Insta's settable accent

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

The only differences between Pocket's and Insta's shared UI are `MonitorTheme.swift` and
`MonitorTheme.kt`. Plan 7.2 asks for a small injected brand configuration instead of forks.

## Decision

Insta's `MonitorTheme` (settable `accentRGB`/`accent`, default Pocket blue `0x00A3E0`, plus
`onAccent`) becomes the shared theme in `opencineui`. Each app sets its accent at the
composition root. Pocket's default rendering is unchanged.

## Consequences

Recorded as a candidate `source-copy` edge from `opencineui` to `openinstacine` for the theme
files, alongside the main edge to `openpocketcine`.
