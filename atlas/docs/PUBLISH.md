# Publishing: the morning runbook

Nothing is published yet (ADR 0001). One command does it, in dependency order, and can be
stopped and resumed at any point: `tools/publish.py`. It is a dry run unless you pass
`--execute`. Everything it does is driven by [compat/release-0.1.0.json](../compat/release-0.1.0.json)
(tag order, expected commits, test evidence, verify commands) and recorded in the ignored
`.local/publish-state.json`. Version rules: [compat/VERSIONS.md](../compat/VERSIONS.md).

The whole flow was rehearsed against `file://` remotes on disposable clones of every repository
(`tools/rehearse_publish.py`; results in the RELEASE-01 notes of the run ledger).

## 1. Decide (four values, recorded in the release record)

| Decision | Recommendation | Why |
|---|---|---|
| `owner` | `erik-sutton95` | The three apps live there; one owner keeps package URLs short and stable. |
| `visibility` | `public` | The apps are open source. Contributors and Xcode Cloud must resolve the packages without credentials. Private repos would also break `https://` resolution on this Mac (see section 7). |
| `android` | `sibling-pins` | The only automated option. Gradle keeps including the packages' builds from sibling checkouts, pinned to the `0.1.0` tag commits. A Maven namespace is a later, separate release (section 8). |
| `author_email` | `9084979+erik-sutton95@users.noreply.github.com` | OpenCineCore, Multicam, DJI, Nikon, Insta360 and Harness have commits authored as `another address` and some as `eriks.indesign@gmail.com`. Publishing them exposes both addresses, and GitHub refuses the push (GH007) if email privacy blocks one. `keep` publishes them as they are. |

Also before running:

- Review the three `opencine/integration` branches and the seven package `main` branches. Other
  agents must be finished: every repository must be clean and at its recorded commit.
- Write the tester notes on each app branch (section 6): the apps' CI fails the pull request
  without them. You can do this before or after publishing; the PRs are drafts.

## 2. Commands

```sh
cd ~/Work/opencapture-atlas
export JAVA_HOME=/opt/homebrew/opt/openjdk@24/libexec/openjdk.jdk/Contents/Home  # Gradle verify steps
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools

python3 tools/publish.py                       # dry run: preflight plus every diff; writes nothing
python3 tools/publish.py decide --owner erik-sutton95 --visibility public \
  --android sibling-pins --author-email 9084979+erik-sutton95@users.noreply.github.com
python3 tools/publish.py rewrite-authors       # preview; then:
python3 tools/publish.py rewrite-authors --execute
python3 tools/publish.py                       # dry run again: "preflight: passed"
python3 tools/publish.py --execute --open-prs  # publish everything, open draft app PRs
```

`decide`, `record` and `rewrite-authors --execute` commit the release record in the atlas.
If a repository moved after its tests were recorded (another agent committed), rerun its tests,
then record the new commit and where the green run is written down:

```sh
python3 tools/publish.py record opencinecore --evidence "swift test 290/40 suites, 2026-10-02 notes"
```

To rehearse again first (about an hour, mostly app builds):
`python3 tools/rehearse_publish.py --dir /tmp/opencine-publish-rehearsal`.

## 3. What each step does

Preflight (always, also in the dry run): the four decisions are recorded and match `--owner` and
`--visibility`; every checkout is clean, on its branch, at its recorded commit, with passed
evidence recorded for that commit; commit emails are publishable; `git`, `gh`, `swift`, `just`,
`xcodegen`, `xcodebuild`, `JAVA_HOME` and `ANDROID_HOME` are available; `gh auth token --user
erik-sutton95` works. It warns about app tester notes not yet changed on a branch.

Then, in this order (each line is one resumable step):

| Repository | Steps |
|---|---|
| `opencapture-atlas` | `gh repo create` (skipped if it exists), `origin` = `git@github.com-personal:<owner>/opencapture-atlas.git`, push `main` |
| OpenCineCore, then OpenCineUI, OpenCineMulticam, OpenCineDJI, OpenCineNikon, OpenCineInsta360, OpenCineHarness | create and add `origin` as above; rewrite path dependencies on released packages to `.package(url: "https://github.com/<owner>/<Name>", .upToNextMinor(from: "0.1.0"))` and commit; verify in a clean clone with no local overrides (the release record's `verify`, e.g. `swift build --build-tests`, `swift test`, Gradle where the package has Android); annotated tag `0.1.0`; push `main` and the tag |
| OpenPocketCine, OpenInstaCine, OpenZCine (`opencine/integration` worktrees) | rewrite `Package.swift`, `ios/project.yml` (XcodeGen) or `ios/Runner.xcodeproj` (Nikon) to `url` + exact `0.1.0`; rewrite `opencine-pins.txt` to the tag commits; drop the sibling checkout from iOS CI jobs and Xcode Cloud `ci_post_clone.sh` (kept, with a corrected comment, in Gradle jobs); resolve (`just ios-resolve`, `swift package resolve`, or `xcodebuild -resolvePackageDependencies` for Nikon) and commit `Package.resolved` files; verify in a clean clone: `swift test`, the app's own Package.resolved check, `xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution` (what Xcode Cloud does), `just ios-build`, all before any sibling exists, then `scripts/checkout-opencine.sh` from the new remotes and `just android-check`; push the branch to `git@github.com-personal:erik-sutton95/<App>.git`; with `--open-prs`, a draft PR whose body lists the work packages, versions, evidence, notes files and the device checklist |
| `opencapture-atlas` | set `repository.url` for the atlas and every package; package refs to the tag commits; app candidate refs to the pushed branches; packages `active` and library edges `live` only when every app PR exists; regenerate `compat/VERSIONS.md`; `atlas check --sources`; commit; push |

Libraries get a compatible range (harness finding F2); apps get exact pins plus committed lock
files (plan 10.1). The range is `upToNextMinor` because a 0.x minor bump is incompatible.

Every step that edits a repository prints its full diff in the dry run. It also lists docs in
that repository that still describe sibling checkouts; those are not rewritten automatically.

## 4. Stopping, failing, resuming

A failed step prints `STOPPED`, the cause and (for builds) the last lines of its log under
`.local/publish-logs/`. Nothing after it runs. Fix the cause and rerun the same command: finished
steps print `done` and are skipped. Running the finished command again changes nothing.

- A failed app resolve leaves the rewritten files uncommitted in the worktree. Fix or
  `git -C <worktree> checkout -- .` and rerun.
- `--remote-base` and `--version` must match the run that wrote the state. To start over from
  scratch, roll back (section 5) and delete `.local/publish-state.json`.
- `--remote-base file:///path` rehearses against bare repositories you created (`<Name>`, plus a
  `<Name>.git` link for `scripts/checkout-opencine.sh`): no `gh`, and
  the PR step writes its body to `.local/publish/<App>-pr.md` instead.

## 5. Rolling back

Before anything is pushed (state has no `push:` step):

```sh
git -C ~/Work/<Package> reset --hard <commit in the release record>  # drops the URL commit
git -C ~/Work/<Package> tag -d 0.1.0
git -C ~/Work/<Package> remote remove origin
git -C ~/Work/<App>-opencine-integration reset --hard <commit in the release record>
mv .local/publish-state.json .local/publish-state.rolled-back.json
```

After `rewrite-authors`, the old history stays under `refs/original/refs/heads/main` in each
rewritten package: `git -C ~/Work/<Package> reset --hard refs/original/refs/heads/main`, then
`publish.py record` the old commit again.

After pushing (a published `0.1.0` tag is permanent once anyone resolved it; prefer fixing
forward with `0.1.1`). If nothing depends on it yet:

```sh
export GH_TOKEN=$(gh auth token --user erik-sutton95)
gh pr close <number> --repo erik-sutton95/<App> --delete-branch      # app PRs
gh auth refresh -h github.com -s delete_repo                          # once, adds the scope
gh repo delete erik-sutton95/<Repo> --yes                             # each new repository
```

then the local steps above, and `git -C ~/Work/opencapture-atlas reset --hard <atlas commit
before the run>`.

## 6. After publishing: checks

- **Package CI**: each new repository's `CI` workflow runs on the pushed `main` (Swift; Gradle
  for Core, UI, Multicam and Insta360). All green before anyone merges an app PR.
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
- **Xcode Cloud**: start a build of each branch. `ci_post_clone.sh` no longer checks out
  siblings; Xcode Cloud resolves with `-disableAutomaticPackageResolution` from the committed
  lock file (`ios/Package.resolved` copied by `sync-package-resolved.sh` for Pocket and Insta;
  the tracked workspace `Package.resolved` for Nikon). Public package repos need no Xcode Cloud
  repository grant; private ones do (App Store Connect, Xcode Cloud settings).
- **Atlas**: the run already passed `atlas check --sources`. Review `compat/VERSIONS.md` and the
  atlas CI run on GitHub.
- **Device checklists**: linked from each PR body; nothing here is hardware-qualified.

After an app PR merges: move that app's atlas `refs` to the merged commit, record its `library`
edges as `live` with manifest evidence, remove `source-copy` edges only for paths the app no
longer copies (for Insta, also drop them from `scripts/sync-openpocketcine.sh`), run
`python3 tools/atlas.py check --sources` and push the atlas.

## 7. Local development after publishing

Manifests never switch on environment variables: the committed manifest and lock file must
describe exactly what CI and Xcode Cloud build. Use the package managers' own overrides instead.

- **SwiftPM command line** (packages and app roots): `swift package edit OpenCineCore --path
  ../OpenCineCore` uses your checkout until `swift package unedit OpenCineCore`.
- **Xcode**: drag the local package folder into the project (or workspace) navigator. A local
  package with the same identity overrides the remote one until you remove it
  ([Apple: editing a package dependency as a local package](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)).
- **Android**: unchanged for now. Gradle includes the sibling checkouts (`../../../<Name>/Android`);
  `scripts/checkout-opencine.sh` reports drift from `opencine-pins.txt` and never moves your checkout.
- **Release validation** always runs without overrides: `publish.py` verifies in fresh clones.
- `atlas compat run` (OPS-01) still substitutes candidates by sibling path, which Apple builds no
  longer read after the switch; it needs an override step before it can validate the next
  package candidate for iOS.
- On this Mac, `~/.gitconfig` rewrites `https://github.com/erik-sutton95/` to
  `git@github.com:erik-sutton95/`, which uses the work key. Public repositories resolve fine;
  private ones would not.

## 8. Android artifacts later (ADR 0007)

When you choose a Maven namespace (`org.opencapture` is verifiable through `opencapture.org`;
JitPack is the zero-setup fallback; not GitHub Packages, which needs credentials even for public
packages): set the group in each package's Gradle build (currently `com.opencapture.opencine`),
publish `0.1.x` (or the next minor if coordinates change), replace each app's `includeBuild` with
the coordinate in `gradle/libs.versions.toml`, keep `includeBuild` only behind an untracked
property (for example `opencine.ui.dir`), and remove `opencine-pins.txt` and
`scripts/checkout-opencine.sh` from the apps.

## Accounts on this machine

- Pushes to `erik-sutton95` repositories use the SSH alias `github.com-personal`
  (`git@github.com-personal:erik-sutton95/<Repo>.git`); plain `git@github.com` resolves to the
  wrong key. The script always pushes to explicit URLs.
- `gh` runs as the owner without switching the global login:
  `GH_TOKEN=$(gh auth token --user erik-sutton95) gh <command>` (the script does this).
- New commits and tags use `author_email` from the release record.
