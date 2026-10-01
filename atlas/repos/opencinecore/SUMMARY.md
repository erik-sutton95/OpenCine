# opencinecore (candidate)

Portable contracts from CORE-01: identity values, observations, setting descriptors, command
receipts, monitoring-entry composition, and a test-support product with fake sessions. Status
`candidate`: a local repository; no app consumes it. It must never depend on UI, multicam,
vendor or app code (`tools/atlas.py check` enforces this for recorded and manifest edges).
Build and test instructions: its own `AGENTS.md`.
