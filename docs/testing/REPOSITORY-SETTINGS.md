# Public repository settings

OpenCine follows the OpenPocketCine maintainer baseline. GitHub settings are separate from
committed source; maintainers must verify both after changing the policy.

## Main branch

- Require the strict `CI gate` status check and an up-to-date branch.
- Require one approving review, dismiss stale approvals and resolve conversations.
- Allow merge commits to retain the reviewed source history; disallow force pushes and branch deletion.
- Administrators retain the same bypass as OpenPocketCine (`enforce_admins: false`).
- Use merge commits for cumulative changes; automatically delete merged branches and allow branch updates.
- Auto-merge is available, but enabling it on a PR is a separate maintainer action.

Linear-history enforcement is disabled in OpenCine and the three thin apps so their cumulative
PRs can retain every original source commit. Strict checks, fresh review, stale-approval
dismissal, conversation resolution and force-push/deletion/admin/signature policy are preserved.
Source extraction still lands in OpenCine first, followed by each app's reviewed pin move.

`CI gate` requires the PR tier (Meta, Swift, Android, Atlas) to succeed; a skipped, cancelled or
failed job fails it. Hosted conformance and both SIMULATED new-app jobs run in the nightly tier,
which tracks failures on `main` in one issue ([CI.md](CI.md)). SIMULATED acceptance does not
qualify camera behavior on hardware or ship a consuming app.

## Security and automation

- Enable private vulnerability reporting, Dependabot alerts and security updates.
- Enable secret scanning and push protection.
- Require full action SHA pinning; container actions use immutable digests.
- Default workflow tokens to read-only; disallow bot approval of pull requests.
- Require approval of fork workflows from first-time contributors.
- Enable Discussions and disable the redundant wiki.

Meta checks scan Git history for secrets, reject local/private tracked files, and check
spelling, Markdown, offline links, EditorConfig and workflow syntax. Dependabot checks
GitHub Actions and Android Gradle dependencies weekly. CODEOWNERS names the maintainer;
requiring CODEOWNERS review is not enabled, matching the Pocket baseline.

The reviewed generated Atlas snapshots and third-party/golden bytes retain their original
format. Tool-specific exceptions are documented next to their configuration; they do not
exempt credentials or private captures from scanning. Source review remains necessary for
new binary resources and diagnostics.

See [SECURITY.md](../../SECURITY.md), [contribution guidance](../../CONTRIBUTING.md) and
[repository hygiene](REPOSITORY-HYGIENE.md).
