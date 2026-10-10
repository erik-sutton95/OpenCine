# Publishing: the runbook

Nothing is published yet (ADR 0001). The shared code is one repository, OpenCine, with the
atlas inside it at `atlas/` (ADR 0010). One command publishes it with one tag and moves the
three apps onto that tag, in order, and can be stopped and resumed at any point:
`atlas/tools/publish.py`. It is a dry run unless you pass `--execute`. Everything it does is
driven by [compat/release-0.1.0.json](../compat/release-0.1.0.json) (expected commits, test
evidence, verify commands) and recorded in the ignored `atlas/.local/publish-state.json`. Version
rules: [compat/VERSIONS.md](../compat/VERSIONS.md): one version for everything, and below 1.0 a
minor bump means an incompatible change.

The whole flow is rehearsed against `file://` remotes on disposable clones
(`atlas/tools/rehearse_publish.py`; results in the consolidation notes of the run ledger).

## 1. Decide (four values, recorded in the release record)

| Decision | Recommendation | Why |
|---|---|---|
| `owner` | `erik-sutton95` (recorded) | The three apps live there; one owner keeps the package URL short and stable. |
| `visibility` | `public` | The apps are open source. Contributors and Xcode Cloud must resolve the package without credentials. A private repository would also break `https://` resolution on this Mac (section 7). |
| `android` | `sibling-pins` | The only automated option. Each app's Gradle build keeps including `../../../OpenCine/Android` (named `opencine`) from a sibling checkout pinned to the `0.1.0` tag commit. A Maven namespace is a later, separate release (section 8). |
| `author_email` | `9084979+erik-sutton95@users.noreply.github.com` (recorded) | Every OpenCine commit already uses this personal noreply identity, and the repository has it as its local git identity. Commits and tags this run creates use it too; `rewrite-authors` is a no-op safety check. |

Also before running:

- Review OpenCine `main` and the three `opencine/integration` branches. Other agents must be
  finished: every checkout must be clean and at its recorded commit. OpenCine may be ahead of
  its recorded commit only under `atlas/` (the record and registry live there).
- Write the tester notes on each app branch (section 6): the apps' CI fails the pull request
  without them. You can do this before or after publishing; the PRs are drafts.

## 2. Commands

Run from the OpenCine checkout on `main`:

```sh
cd ~/Work/OpenCine
export JAVA_HOME=/opt/homebrew/opt/openjdk@24/libexec/openjdk.jdk/Contents/Home  # Gradle verify steps
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools

python3 atlas/tools/publish.py                       # dry run: preflight plus every diff; writes nothing
python3 atlas/tools/publish.py decide --visibility public --android sibling-pins
python3 atlas/tools/publish.py rewrite-authors       # preview (nothing to rewrite today)
python3 atlas/tools/publish.py                       # dry run again: "preflight: passed"
python3 atlas/tools/publish.py --execute --open-prs  # publish, open draft app PRs
```

`decide`, `record` and `rewrite-authors --execute` commit the release record under `atlas/` on
the current branch. If a checkout moved after its tests were recorded, rerun its tests, then
record the new commit and where the green run is written down:

```sh
python3 atlas/tools/publish.py record opencine --evidence "swift test 1481, gradle test lint assembleRelease, 2026-10-02 notes"
python3 atlas/tools/publish.py record openpocketcine --evidence "root swift test, iOS suite, android-check, 2026-10-02 notes"
```

To rehearse again first (mostly app builds):
`python3 atlas/tools/rehearse_publish.py --dir /tmp/opencine-publish-rehearsal`. It clones the
committed HEAD of the checkout it runs from as `main`, so a task branch can be rehearsed before
it merges.

## 3. What each step does

Preflight (always, also in the dry run): the four decisions are recorded and match `--owner` and
`--visibility`; every checkout is clean, on its branch, at its recorded commit (OpenCine: or
ahead of it only under `atlas/`), with passed evidence recorded for that commit; commit emails
are publishable; `git`, `gh`, `swift`, `just`, `xcodegen`, `xcodebuild`, `JAVA_HOME` and
`ANDROID_HOME` are available; `gh auth token --user erik-sutton95` works. It warns about app
tester notes not yet changed on a branch.

Then, in this order (each line is one resumable step):

| Repository | Steps |
|---|---|
| OpenCine (`main`) | `gh repo create` (skipped if it exists), `origin` = `git@github.com-personal:<owner>/OpenCine.git`; verify `main` in a clean clone with no local overrides (the release record's `verify`: `swift build --build-tests`, `swift test`, `cd Android && ./gradlew test`, the atlas tests and `atlas check`); annotated tag `0.1.0` on the verified commit; push `main` and the tag. The package has no package dependencies, so nothing is rewritten. |
| OpenPocketCine, OpenInstaCine, OpenZCine (`opencine/integration` worktrees) | issue templates: the chooser (`.github/ISSUE_TEMPLATE/config.yml`) gets an OpenCine link first and the bug form an optional "only in this app, or also another?" question (existing templates are edited, nothing else changes); rewrite `Package.swift`, `ios/project.yml` (XcodeGen) or `ios/Runner.xcodeproj` (Nikon) from `../OpenCine` to `url` + exact `0.1.0`; rewrite `opencine-pins.txt` (one line, `OpenCine <tag commit>`); retain the pinned sibling checkout in jobs running shared `just core-test` sources, notes validators or Gradle; drop it from remote iOS-only jobs and Xcode Cloud `ci_post_clone.sh`; resolve (`just ios-resolve`, `swift package resolve`, or `xcodebuild -resolvePackageDependencies` for Nikon) and commit `Package.resolved` files; verify in a clean clone: `swift test`, the app's own Package.resolved check, `xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution` (what Xcode Cloud does), `just ios-build`, all before any sibling exists, then `scripts/checkout-opencine.sh` from the new remote and `just android-check`; push the branch to `git@github.com-personal:erik-sutton95/<App>.git`; with `--open-prs`, a draft PR whose body lists the work packages, version, evidence, notes files and the device checklist |
| GitHub project | find or create the project `OpenCapture` under the owner (Projects v2), link OpenCine and the three apps, and add every open issue of the four repositories that is not on it yet. Skipped with `--remote-base`. |
| OpenCine atlas | set `repository.url` and the `main` ref (the tag commit) of `opencine`; app candidate refs and their `opencine` edge evidence to the pushed branches; `opencine` becomes `active` only when every app PR exists; regenerate `compat/VERSIONS.md`; `atlas check --sources`; commit on OpenCine `main` (after the tag); push `main` |

The app issue templates are written by this script rather than committed ahead of time: the
integration branches stay at their recorded, tested commits, and templates only take effect on
`main`, which the app pull request reaches. OpenCine's own templates (`.github/ISSUE_TEMPLATE/`)
are ordinary files in this repository.

Apps get an exact pin plus committed lock files (plan 10.1). There is no library range: the
platform depends on no other package.

Insta native CI retains the sibling because `just core-test` also tests
shared integration sources with
`swift test --package-path ../OpenCine --filter Insta360`. The app still
resolves its remote package; the sibling checkout is for those source tests.

Metadata jobs also retain the pinned sibling when the app's TestFlight or
Play notes scripts delegate to shared validators. URL adoption does not
replace those source-based checks with package-manager products.

Every step that edits a repository prints its full diff in the dry run. It also lists docs in
that repository that still describe the sibling checkout; those are not rewritten automatically.

## 4. Stopping, failing, resuming

A failed step prints `STOPPED`, the cause and (for builds) the last lines of its log under
`atlas/.local/publish-logs/`. Nothing after it runs. Fix the cause and rerun the same command:
finished steps print `done` and are skipped. Running the finished command again changes nothing.

- A failed app resolve leaves the rewritten files uncommitted in the worktree. Fix or
  `git -C <worktree> checkout -- .` and rerun.
- `--remote-base` and `--version` must match the run that wrote the state. To start over from
  scratch, roll back (section 5) and delete `atlas/.local/publish-state.json`.
- `--remote-base file:///path` rehearses against bare repositories you created (`<Name>`, plus a
  `<Name>.git` link for `scripts/checkout-opencine.sh`): no `gh`, and the PR step writes its body
  to `atlas/.local/publish/<App>-pr.md` instead.

## 5. Rolling back

Before anything is pushed (state has no `push:` step):

```sh
git -C ~/Work/OpenCine tag -d 0.1.0
git -C ~/Work/OpenCine remote remove origin
git -C ~/Work/<App>-opencine-integration reset --hard <commit in the release record>
mv atlas/.local/publish-state.json atlas/.local/publish-state.rolled-back.json
```

After `rewrite-authors --execute`, the old history stays under `refs/original/refs/heads/main`:
`git -C ~/Work/OpenCine reset --hard refs/original/refs/heads/main`, then `publish.py record` the
old commit again.

After pushing, a published `0.1.0` tag is permanent once anyone resolved it: SwiftPM and Xcode
cache repositories by URL, and a tag that later points at another commit fails to check out on
those machines. Fix forward with `0.1.1`. If nothing depends on it yet:

```sh
export GH_TOKEN=$(gh auth token --user erik-sutton95)
gh pr close <number> --repo erik-sutton95/<App> --delete-branch      # app PRs
gh auth refresh -h github.com -s delete_repo                          # once, adds the scope
gh repo delete erik-sutton95/OpenCine --yes
```

then the local steps above, and `git -C ~/Work/OpenCine reset --hard <main before the atlas
registry commit>`.

## 6. After publishing: checks

- **OpenCine CI**: the `CI` workflow runs on the pushed `main` (Swift build and test with strict
  concurrency, MonitorUI and OpenCineApple simulator builds, Android tests, lint and assemble,
  the Vulkan native test, atlas tests and `atlas check`). Green before anyone merges an app PR.
- **App PR CI**: the required check is `CI gate`. Confirm the Native and Android jobs actually
  ran (path filters skip them silently). Native runs `just native-check`, including the iOS
  simulator suites the publish script does not run.
- **Tester notes gate** (Pocket's merge rules, same scripts in Insta and Nikon): a PR that
  changes production iOS or Android paths fails until it changes the notes files.
  - OpenPocketCine and OpenInstaCine: `ios/TestFlight/WhatToTest.en-US.txt`,
    `Apps/Android/Play/WhatToTest.en-US.txt`, `Apps/Android/Play/whatsnew/whatsnew-en-US`.
  - OpenZCine: `ios/TestFlight/WhatToTest.en-US.txt`, `Apps/Android/distribution/whatsnew/whatsnew-en-US`.
  - Validate with the app's `scripts/ios-release-notes-check.sh` and
    `scripts/android-release-notes-check.sh` (Nikon: `just testflight-notes-check`,
    `just play-notes-check`). Pocket: compose notes and CHANGELOG once for the batch and commit
    the identical set on every branch (merge workflow in its docs).
- **Xcode Cloud**: start a build of each branch. `ci_post_clone.sh` no longer checks out the
  sibling; Xcode Cloud resolves with `-disableAutomaticPackageResolution` from the committed lock
  file (`ios/Package.resolved` copied by `sync-package-resolved.sh` for Pocket and Insta; the
  tracked workspace `Package.resolved` for Nikon). A public repository needs no Xcode Cloud
  repository grant; a private one does (App Store Connect, Xcode Cloud settings).
- **Atlas**: the run already passed `atlas check --sources`. Review `compat/VERSIONS.md`.
- **Device checklists**: linked from each PR body; nothing here is hardware-qualified.
- **OpenInstaCine source ownership**: the former Pocket sync and overlay scripts
  are retired. Common changes belong in OpenCine and reach Insta through a
  reviewed dependency adoption; no overlay URL edit is needed.

After an app PR merges: move that app's atlas `refs` to the merged commit, record its `opencine`
edge as `live` with manifest evidence, remove `source-copy` edges only for paths the app no
longer copies, run
`python3 atlas/tools/atlas.py check --sources` and push.

For OpenInstaCine the narrowed edges are already known (RELEASE-01 sync audit): the Apple
`source-copy` edge keeps only the renamed iOS shell (minus Luna-owned and DJI-only files) and
`tools/` (`stamp-source-revision.sh`, `pull-control-log.sh`, `analyze-live-log.py`); the Android
edge keeps only `Apps/Android/monitor`; `:core-api`, `:monitor-ui` and `:luna-adapter` leave the
product list. Before the next Pocket sync, point the sync base at Pocket's post-integration main
and decide whether Insta adopts OpenCineFrameIO (Pocket's shell imports it now).

## GitHub project: keeping it complete

The project needs the `project` scope on the owner's token, once:
`gh auth switch --user erik-sutton95 && gh auth refresh -h github.com -s project` (switch back
afterwards if another account is your default). New issues reach the project in one of two ways:

- In the project's settings, Workflows, enable "Auto-add to project" with a filter per repository
  (`is:issue is:open`). The number of auto-add workflows depends on the GitHub plan (one on Free).
- Or rerun `python3 atlas/tools/publish.py project` (dry run) and `... project --execute`: it
  finds the project, links the four repositories again (harmless) and adds only issues not on it
  yet. The triage skill runs it after moving issues.

`python3 atlas/tools/atlas.py issues` lists the same open issues locally without the project.

## 7. Local development after publishing

Manifests never switch on environment variables: the committed manifest and lock file must
describe exactly what CI and Xcode Cloud build. Use the package managers' own overrides instead.

- **SwiftPM command line** (app roots): `swift package edit OpenCine --path ../OpenCine` uses your
  checkout until `swift package unedit OpenCine`.
- **Xcode**: drag the local OpenCine folder into the project (or workspace) navigator. A local
  package with the same identity overrides the remote one until you remove it
  ([Apple: editing a package dependency as a local package](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)).
- **Android**: unchanged for now. Gradle includes `../../../OpenCine/Android` (named `opencine`);
  `scripts/checkout-opencine.sh` reports drift from `opencine-pins.txt` and never moves your checkout.
- **Release validation** always runs without overrides: `publish.py` verifies in fresh clones.
- `atlas compat run` substitutes the candidate by sibling path, which Apple builds no longer read
  after the switch; it needs an override step before it can validate the next candidate for iOS.
- On this Mac, `~/.gitconfig` rewrites `https://github.com/erik-sutton95/` to an SSH URL that
  uses a different key. A public repository resolves fine; a private one would not.

## 8. Android artifacts later (ADR 0007)

When you choose a Maven namespace (`org.opencapture` is verifiable through `opencapture.org`;
JitPack is the zero-setup fallback; not GitHub Packages, which needs credentials even for public
packages): set the group in OpenCine's Gradle modules (currently `com.opencapture.opencine`, one
version for all), publish `0.1.x` (or the next minor if coordinates change), replace each app's
`includeBuild` with the coordinates in `gradle/libs.versions.toml`, keep `includeBuild` only
behind an untracked property (for example `opencine.dir`), and remove `opencine-pins.txt` and
`scripts/checkout-opencine.sh` from the apps.

## Accounts on this machine

- Pushes to `erik-sutton95` repositories use the SSH alias `github.com-personal`
  (`git@github.com-personal:erik-sutton95/<Repo>.git`); plain `git@github.com` resolves to the
  wrong key. The script always pushes to explicit URLs.
- `gh` runs as the owner without switching the global login:
  `GH_TOKEN=$(gh auth token --user erik-sutton95) gh <command>` (the script does this).
- New commits and tags use `author_email` from the release record.
