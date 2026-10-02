# ADR 0004: Shared theme takes Insta's settable accent

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

The only differences between Pocket's and Insta's shared UI are `MonitorTheme.swift` and
`MonitorTheme.kt`. Plan 7.2 asks for a small injected brand configuration instead of forks.

## Decision

Insta's `MonitorTheme` API (settable `accentRGB`/`accent`, plus `onAccent`) becomes the shared
theme in `opencineui`. Each app sets its accent at the composition root. Defaults are Pocket's
shipped accents so Pocket's rendering is unchanged: iOS `0x00A3E6` (0, 163, 230) and Android
`0x00A3E0`.

Correction (recorded after UI-01): the run ledger and Insta's Swift copy used `0x00A3E0` as
the default, which matches only Pocket's Android value. The `opencineui` Swift theme restores
the iOS value (evidence: Pocket `Sources/MonitorUI/MonitorTheme.swift` at `27b15028`,
`edrAccent` uses 163/255 and 230/255).

## Consequences

Recorded as a candidate `source-copy` edge from `opencineui` to `openinstacine` for the theme
files, alongside the main edge to `openpocketcine`.
