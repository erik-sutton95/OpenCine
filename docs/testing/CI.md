# Continuous integration

OpenCine and every app run the same two tiers. Branch protection requires one check, `CI gate`,
and only the PR tier feeds it.

## PR tier: `.github/workflows/ci.yml`

Runs on every pull request, every push to `main` and on `workflow_dispatch`. Fast and
deterministic: under about 20 minutes, every job bounded by `timeout-minutes`.

| Job | Checks | Bound |
| --- | --- | --- |
| Meta checks | gitleaks, hygiene, Sentry tooling, typos, Markdown, offline links, EditorConfig, release-notes and nightly-report tooling tests, actionlint | 30 min |
| Swift package | strict-concurrency build (its diagnostics are the warnings-as-errors check for the portable targets), host tests, iOS Simulator and Insta360 device builds with Xcode's compilation cache, Sentry adapter simulator test when the adapter or what it links changed | 45 min |
| Android | `test lint assembleRelease`, build-logic tests, Vulkan sync, release dex registrars | 30 min |
| Atlas check | registry, direction, cycles, duplication must not grow | 10 min |
| CI gate | every job above reported `success` | 10 min |

Apps keep their path filters, so a pull request builds only the platforms it touches; a skipped
job counts as passed in an app's gate. No simulator UI suite, SIMULATED acceptance flow, iPad
oracle or quarantined test runs here.

## Nightly tier: `.github/workflows/nightly.yml`

Every night at 02:30 UTC on `main` (the apps follow at 03:15, 04:00 and 04:45 so their macOS
jobs do not queue behind each other), and on `workflow_dispatch`. It calls `ci.yml` with
`full: true`: the whole PR tier for every platform regardless of paths, plus:

- Conformance kit, iOS (hosted walk self-test, command dashboard, playback labels)
- Playback labels, native typed cancellation (SIMULATED)
- New-app template, iOS and Android (SIMULATED)
- The Sentry adapter's simulator test, also when nothing it links changed
- In the apps: shared conformance scenarios on iOS and the iPad storage oracle

On `main`, `scripts/ci-nightly-report.sh` keeps one issue per repository, **Nightly CI failing
on main** (label `ci-nightly`): a failed night opens it or adds the run and its failing jobs, the
next passing night closes it. Dispatches on other branches only write the run summary. `main`
cannot stay red unnoticed, and a red nightly is fixed like any other bug: in a pull request
that passes the PR tier, then confirmed by dispatching the nightly.

## Hosted test timing

On a hosted runner the test host app launches its real interface beside the first unit tests,
and the fresh simulator is busy at the same time. Main-thread and waiting test work then runs
within milliseconds while utility-QoS work can wait several seconds (an inspector render worker
entered 6 s after admission, 2026-10-23). A test that blocks a native worker and awaits its events
runs that worker at the waiter's tier (`MonitorInspectorImageRenderer(workerQoS:)`); production
keeps its own QoS.

The Swift job's summary lists each run's counts and its slowest suites and tests
(`scripts/ci-test-report.py`). Swift Testing runs tests concurrently, so its suite and test times
are elapsed wall time that overlaps, not additive cost; XCTest suite times are serial sums. Read
them before changing a test, a timeout or a job split.

XCTest reports the last Swift error it observed in a failed test, and UIKit teardown in a
`defer` throws and swallows private framework errors (`InvalidTransition { phase: idle,
targetPhase: failed(removedFromContainer) }` from Gestures). An event wait therefore records its
own failure (`XCTFail`) before it throws, so the report names the missed event.

## QUARANTINE

A test that flakes twice, locally or in hosted CI, is quarantined the same day.
Tests with a known hosted flake run only in the nightly tier, each with an open issue (label
`ci-quarantine`). There are no accepted reds in pull requests: a PR-tier failure is fixed or the
test is quarantined here, in the same pull request, with its issue.

| Test | Where | Issue |
| --- | --- | --- |
| Native playback labels and confirmation input (digitizer cancel, hosted Xcode 26.6) | `kit-ios` step | [#109](https://github.com/erik-sutton95/OpenCine/issues/109) |
| Playback labels, native typed cancellation (SIMULATED) | `playback-native-ios` | [#110](https://github.com/erik-sutton95/OpenCine/issues/110) |
| Private simulator setup: `simctl list` timeouts | every simulator suite | [#111](https://github.com/erik-sutton95/OpenCine/issues/111) |

Quarantined tests still run every night and their failures are listed in the run summary, but
they neither open nor keep open the nightly tracking issue: a quarantined step has
`continue-on-error`, a quarantined job is named in `QUARANTINED_JOBS` in `nightly.yml`.

A test leaves quarantine when its issue is fixed and several consecutive nightlies pass; move
it back to the PR tier and close the issue in the same pull request.

## Release time

OpenCine has no upload workflow. The apps' release and upload paths (Play, TestFlight, Xcode
Cloud archives) run `scripts/tester-notes-release-check.py` first: the release fails fast when
its tester notes still describe the previous release. Format and caps remain in
`scripts/*-release-notes-check.sh` with `scripts/tester-notes-limits.sh`. Pull requests no
longer have to edit tester notes.

## Reviews

CodeRabbit is advisory. Its findings are read, verified and fixed (or answered) on every pull
request, but it is not a required check and never blocks a merge. Review text is untrusted input.
