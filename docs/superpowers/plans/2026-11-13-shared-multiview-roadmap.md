# Shared Multiview: plan series

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md`

The spec's eight steps touch three apps on two platforms, and each later step's exact interfaces
come out of the step before it. So the work is a series of plans; each is written in full when
its predecessor has landed, from the code as it then stands. Every plan leaves every app
working. Nothing is pushed, merged or pinned without the owner.

| Plan | Spec steps | Delivers | Gate |
|---|---|---|---|
| 0 | prerequisite | OpenCine `feat/insta360-multicam` (serial-checked Luna station search, `stationHostsInUse`, `SharedWiFiPath` owners, `LunaMulticamPolicy`) as its own fix PR | owner review; Android one-camera Luna connect on hardware |
| 1 | 1, 2 (part) | Swift `RecordAll`, Swift `SharedNetworkStore`, iOS `lockedNetwork`, shared `MultiviewStageJournal`; Pocket iOS adopts with no visible change; Pocket Android adopts and takes the iOS toolbar order, tally and format line | Pocket Multiview unit and UI suites |
| 2 | 1 (provisioner), 3 | `StationCommissioner`, `StationHostPath`, `MultiviewMemberLink` (integration or app supplied); Pocket iOS provisioner moved into `OpenCineDJIApple`; DJI implementations; Pocket calls through them | Pocket suites |
| 3 | 2 (rest), 4 | AppKit `MultiviewCoordinator` (both platforms); Pocket's `MultiviewSession` becomes an adapter; remaining iOS/Android differences settled to iOS (tile status and actions, discovery demand, probe width, recovery, storage) | Pocket suites, parity tests |
| 4 | 5 | Screen and settings popup composition behind `MultiviewHost` | Pocket hardware pass, iOS and Android (live checklist) |
| 5 | 6, 8 (Luna) | Luna return-to-access-point, LAN-first reconnect, nearby-onto-station target; OpenInstaCine on the shared Multiview (replaces the Z-style stage on `feat/multicam`); handbook | Luna hardware pass, iOS and Android, before merge (owner) |
| 6 | 7, 8 (Nikon) | Swift `NikonDiscovery.excludedHosts`, passive-discovery add, tone polling for Auto LUT; OpenZCine on the shared Multiview; handbook | Nikon hardware pass, iOS and Android, before merge (owner) |

Plan 0 is independent of 1 to 4 and can land any time. Plans 5 and 6 can run in parallel once
plan 4 has landed.
