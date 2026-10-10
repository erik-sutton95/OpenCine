# Contributing to OpenCine

OpenCine owns behavior shared by the OpenCapture camera apps. Start with
[README.md](README.md), [AGENTS.md](AGENTS.md) and the guide for the area you are changing.

## Find the right owner

Report an app's setup, transport or camera behavior in its app tracker when the shared cause is
not yet known. For a shared defect, identify the source owner and consumers:

```sh
python3 atlas/tools/atlas.py impact <symbol-or-path>
python3 atlas/tools/atlas.py locate <repository>
```

The [atlas routing guide](atlas/docs/ROUTING.md) describes issue routing. It can create a task
folder with a separate worktree for each affected repository; do not overwrite a shared checkout
or unrelated work. Machine paths and evidence belong in ignored `atlas/.local/` folders.

## Make a focused change

- Preserve the dependency boundaries in the manifests. Add no third-party package dependency.
- Choose capability and observed-value checks, never manufacturer or app-name branches.
  Unknown remains `nil`; a displayed value does not establish command authority.
- Keep integration code UI-free. Use a common setting, a typed optional service, or a bounded
  integration-owned content slot in that order; preserve the common screen owner.
- Keep Swift and Kotlin behavior in step, or document a justified platform exception.
- Retain source identity, operation admission, cancellation and native ownership fences.
- Read the [native runtime guide](docs/native-runtime/README.md) before changing frame ownership,
  processing or sampling. Preserve JNI contracts and native consumer checks.
- Use Conventional Commits, stage paths explicitly and keep secrets, captures, credentials and
  signing material out of Git. Do not add co-author trailers or em dash characters to edited text.

## Verify and describe the result

Run the shared checks in [AGENTS.md](AGENTS.md) from your worktree. Shared behavior changes also
need each affected app's own checks. Device tests use task-owned resources and restore the
operator's settings. Operator-visible behavior needs physical evidence on each affected platform
or an explicit `untested` statement.

A pull request should explain the concrete problem, resulting behavior, consumers, verification
scope and remaining limits. Preserve existing fixtures and assertions. Label SIMULATED scenarios
and distinguish compilation, automated checks, hardware qualification, integration and release.
Keep corresponding area documentation current.

Publishing, app pin moves, tags and merges require their own authorization. Follow
[the publish guide](atlas/docs/PUBLISH.md); a shared commit does not update an installed app.

## Local commit checks

Install Gitleaks and enable the optional per-clone hook:

```sh
git config core.hooksPath .githooks
scripts/check-repository-hygiene.sh
gitleaks detect --source=. --redact --no-banner --config=.gitleaks.toml
```

The hook scans the Git index before committing. CI repeats the history secret scan and
repository hygiene checks; see [the hygiene policy](docs/testing/REPOSITORY-HYGIENE.md).

## Community and security

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Use
[shared issues](https://github.com/erik-sutton95/OpenCine/issues/new/choose) for shared defects and
[Discussions](https://github.com/erik-sutton95/OpenCine/discussions) for questions and ideas.
Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
