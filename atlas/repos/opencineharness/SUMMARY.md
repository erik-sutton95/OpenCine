# opencineharness (candidate)

Developer-only harness from MULTI-03 that proves cross-brand composition with SIMULATED cameras:
HarnessEngine (neutral per-source analysis settings and synchronization levels beside
OpenCineMulticam) and HarnessComposition (the explicit list of integration factories, the only
module that names a manufacturer). Depends on OpenCineCore, OpenCineMulticam, OpenCineDJI,
OpenCineNikon and OpenCineInsta360; nothing may depend on it (layer `harness`). Nothing here ships
and nothing is hardware-qualified; findings F1 to F7 are in its `docs/TOPOLOGY.md` and README.
Build and test instructions: its own `AGENTS.md`.
