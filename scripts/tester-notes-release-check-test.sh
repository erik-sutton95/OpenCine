#!/usr/bin/env bash
# Regression tests for the release-time tester notes freshness check (offline, explicit releases).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="${script_dir}/tester-notes-release-check.py"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

cd "$temp_dir"
git init --quiet -b main
git config user.name test
git config user.email test@example.invalid
commit() {
  git add -A
  git commit --quiet -m "$1"
  git rev-parse HEAD
}

expect_pass() {
  if ! python3 "$check" --notes notes.txt "$@" >/dev/null 2>&1; then
    printf 'Expected the notes release check to pass: %s\n' "$*" >&2
    exit 1
  fi
}

expect_fail() {
  if python3 "$check" --notes notes.txt "$@" >/dev/null 2>&1; then
    printf 'Expected the notes release check to fail: %s\n' "$*" >&2
    exit 1
  fi
}

printf 'base\n' > code.txt
before_notes="$(commit 'release before these notes')"
printf 'first\n' > notes.txt
commit 'notes for release one' >/dev/null
printf 'a\n' >> code.txt
released="$(commit 'feature after the notes')"

# A release that predates the notes, or one this clone does not have: fresh.
expect_pass --released-sha "$before_notes" --released-sha 0123456789abcdef0123456789abcdef01234567
printf 'b\n' >> code.txt
head_unreleased="$(commit 'more work')"

# A release that already carried these notes makes them stale for the next release.
expect_fail --released-sha "$released"
# The release commit itself may be released again (re-run of the same build).
git checkout --quiet "$released"
expect_pass --released-sha "$released"
git checkout --quiet main

# New notes after the last release are fresh again.
printf 'second\n' > notes.txt
commit 'notes for release two' >/dev/null
expect_pass --released-sha "$released"

# A release on a side branch that contains the notes still counts.
git checkout --quiet -b side "$head_unreleased"
printf 'side\n' > side.txt
side_release="$(commit 'side release')"
git checkout --quiet main
git reset --quiet --hard "$head_unreleased"
expect_fail --released-sha "$side_release"

# Every notes file must be fresh, and a missing file fails.
printf 'store copy\n' > short.txt
commit 'short copy' >/dev/null
if python3 "$check" --notes notes.txt --notes short.txt --released-sha "$released" >/dev/null 2>&1; then
  printf 'Expected stale notes.txt to fail even with fresh short.txt.\n' >&2
  exit 1
fi
expect_fail --notes missing.txt --released-sha "$before_notes"

# Workflow runs: a successful run counts only when its upload job succeeded.
mkdir "$temp_dir/bin"
cat > "$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
case "${*: -1}" in
  */workflows/play.yml/runs*) printf '{"workflow_runs":[{"head_sha":"%s","id":1}]}' "$FAKE_RUN_SHA" ;;
  */runs/1/jobs*) printf '{"jobs":[{"name":"Build & upload","conclusion":"%s"}]}' "$FAKE_JOB" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$temp_dir/bin/curl"
workflow_check() {
  PATH="$temp_dir/bin:$PATH" FAKE_RUN_SHA="$released" FAKE_JOB="$1" python3 "$check" --repo owner/repo \
    --released-by-workflow play.yml --release-job 'Build & upload' --notes notes.txt >/dev/null 2>&1
}
if workflow_check skipped; then :; else
  printf 'Expected a run with a skipped upload job not to count as a release.\n' >&2
  exit 1
fi
if workflow_check success; then
  printf 'Expected a run with a successful upload job to count as a release.\n' >&2
  exit 1
fi

printf 'Tester notes release check tests passed.\n'
