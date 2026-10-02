# opencineui (candidate)

Shared design system: Swift `MonitorPresentation` and `MonitorUI`, Compose `monitor-ui`
(`Android/`, coordinate group recorded in `repos/opencineui/meta.json`). Status `candidate`:
a local repository extracted by UI-01/UI-02 from the frozen Pocket donor `27b15028`, with
Insta's settable-accent theme (ADR 0004). Not published (ADR 0001).

## Connections

- Consumed only on Pocket candidate branches (`opencine/ui-01-swift`, `opencine/ui-02-android`)
  by relative path; `tools/atlas.py deps openpocketcine` shows the manifest evidence. No
  baseline app consumes it.
- Still a copy of Pocket's sources, so a fix in either place must be mirrored until Pocket's
  adoption merges and its local copies are deleted.

Route here once adopted: shared tokens, controls, panels and layouts. Until then the owning
source of truth for shipped apps is `openpocketcine`. Build and test instructions: its own
`AGENTS.md`.
