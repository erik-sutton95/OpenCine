# OpenCineHarness agent guide

- Developer-only, SIMULATED harness (plan MULTI-03). Never add a product dependency, an app target,
  store metadata or anything that ships. Never describe a result here as hardware evidence.
- Build and test: `swift build --build-tests && swift test`. Needs the five sibling packages at the
  SHAs in `opencine-pins.txt` (`scripts/checkout-opencine.sh`); `scripts/check-closure.sh` must pass.
- Never modify the packages from here. A seam defect goes into README "Seam findings" with a
  proposed fix, plus a test (use `withKnownIssue` for behavior the owner must change).
- `HarnessEngine` imports OpenCineCore, OpenCineMedia and OpenCineMulticam only and never names a
  manufacturer (a test scans it). Vendor code belongs in `HarnessComposition` or the tests.
- Integrations are listed explicitly in `Composition.factories`: no registry, no plugin loading.
- Label every new scenario SIMULATED and keep `docs/TOPOLOGY.md` honest: nothing is qualified
  until a recorded physical run says so.
- Never use the em dash character. Commits: no co-author trailers.
