# Publishing the local repositories

Nothing has been published (ADR 0001). Run these steps only after deciding hosting,
visibility and the Android coordinate group (ADR 0007). Placeholders: `<workspace>` is the
folder holding the sibling checkouts; `<version>` is the first tag, for example `0.1.0`.

## 0. Accounts on this machine

- Pushes to `erik-sutton95` repositories use the SSH host alias `github.com-personal`:
  `git@github.com-personal:erik-sutton95/<Repo>.git`.
- Run `gh` as that account without switching the global login:
  `GH_TOKEN=$(gh auth token --user erik-sutton95) gh <command>`.
- Commits in these repositories use the repo-local noreply email already configured in each
  checkout (`git -C <checkout> config user.email`).

## 1. Create and push the new repositories

For each of `opencapture-atlas`, `OpenCineUI`, `OpenCineCore` (choose `--public` or
`--private`; the apps are open source, so packages they depend on must be public for
contributors to resolve them):

```sh
GH_TOKEN=$(gh auth token --user erik-sutton95) gh repo create erik-sutton95/<Repo> --public \
  --description "<one line>"
git -C <workspace>/<Repo> remote add origin git@github.com-personal:erik-sutton95/<Repo>.git
git -C <workspace>/<Repo> push -u origin main
```

Then in the atlas:

1. Set `repository.url` to `https://github.com/erik-sutton95/<Repo>` in
   `repos/opencapture-atlas/meta.json`, `repos/opencineui/meta.json`,
   `repos/opencinecore/meta.json`.
2. Add a `refs` entry (`main`, full SHA, role `baseline`) for each package.
3. Run `python3 tools/atlas.py check --sources`.

## 2. Tag package releases

```sh
git -C <workspace>/OpenCineUI tag -a <version> -m "OpenCineUI <version>"
git -C <workspace>/OpenCineUI push origin <version>
```

SwiftPM needs plain semantic-version tags (`0.1.0`, not `v0.1.0`). During `0.x`, an
incompatible interface change bumps the minor version (plan 10.1).

## 3. Publish the Android artifact

Pick one (ADR 0007):

- **Maven Central** (recommended): register the namespace (`org.opencapture` is verifiable
  through `opencapture.org`), set the group in `OpenCineUI/Android` (currently
  `com.opencapture.opencine` on the candidate branches; change it here if needed), sign and
  publish `monitor-ui:<version>`.
- **JitPack** (zero setup): coordinates become `com.github.erik-sutton95:OpenCineUI:<version>`
  (or the module path JitPack reports); no credentials for consumers.
- Do not use GitHub Packages for public consumption: it requires authentication.

## 4. Convert the app candidate branches (required)

The candidate branches commit hard sibling paths only because no remotes existed. Before any
app pull request:

- **XcodeGen** (`ios/project.yml`): replace
  `OpenCineUI: { path: ../../OpenCineUI }` with
  `OpenCineUI: { url: https://github.com/erik-sutton95/OpenCineUI, exactVersion: <version> }`.
  Regenerate, resolve and commit `ios/Package.resolved` (Pocket and Insta have
  `just ios-resolve`; check the app's own justfile).
- **SwiftPM** (`Package.swift`, if an app package depends on it directly):
  `.package(url: "https://github.com/erik-sutton95/OpenCineUI", exact: "<version>")`.
- **Gradle** (`Apps/Android/settings.gradle.kts`): remove the unconditional
  `includeBuild("../../../OpenCineUI/Android")`; depend on the published coordinate in
  `gradle/libs.versions.toml`; keep `includeBuild` only behind an untracked property:

  ```kotlin
  // settings.gradle.kts: opt-in local override, never the default
  val localUi = providers.gradleProperty("opencine.ui.dir").orNull
  if (localUi != null) {
      includeBuild(localUi) {
          dependencySubstitution {
              substitute(module("<group>:monitor-ui")).using(project(":monitor-ui"))
          }
      }
  }
  ```

  Developers set `opencine.ui.dir=<path>` in `~/.gradle/gradle.properties` or an untracked
  `local.properties`-style file.
- **Xcode local override** for package development: add the local `OpenCineUI` checkout to the
  workspace; Xcode prefers it over the remote package until removed.
- Verify a clean clone builds with no override (plan 10.3: release validation runs without
  local overrides). Then register the app branch as a candidate ref in the atlas and run
  `python3 tools/atlas.py deps <app>`; the manifest-derived edge should name the URL, not a path.

## 5. Push app branches and open pull requests

```sh
git -C <app worktree> push -u origin <branch>
GH_TOKEN=$(gh auth token --user erik-sutton95) gh pr create --repo erik-sutton95/<App> \
  --base main --head <branch> --title "<title>" --body "<body>"
```

Normal review applies; nothing auto-merges. App CI path filters do not yet react to package
pin changes (plan 11.6); check that the Native and Android jobs actually ran.

## 6. After merge

- Update the atlas: app `refs` to the merged SHA, add `library` edges with manifest evidence,
  set `opencineui` status `active`, and remove `source-copy` edges only for paths the app no
  longer copies (for Insta, also drop those paths from `scripts/sync-openpocketcine.sh`).
- Run `python3 tools/atlas.py check --sources` and commit.
- Push the atlas: `git -C <workspace>/opencapture-atlas push`. Its CI
  (`.github/workflows/atlas.yml`) runs the unit tests and `atlas check`.
