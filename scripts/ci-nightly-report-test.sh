#!/usr/bin/env bash
# Regression tests for the nightly tracking issue, against a recording gh stand-in.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
report="${script_dir}/ci-nightly-report.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir "$temp_dir/bin"
cat > "$temp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "api --paginate") printf '%b' "${FAKE_FAILED_JOBS:-}" ;;
  "issue list")
    # Apply the caller's --jq filter to a listing that also holds a mirrored tracker.
    arguments="$*"
    issues='{"number":9,"title":"[OpenZCine#457] Nightly CI failing on main"}'
    if [ -n "${FAKE_OPEN_ISSUE:-}" ]; then
      issues="$issues,{\"number\":$FAKE_OPEN_ISSUE,\"title\":\"Nightly CI failing on main\"}"
    fi
    printf '[%s]' "$issues" | jq -r "${arguments##*--jq }"
    ;;
esac
EOF
chmod +x "$temp_dir/bin/gh"

run() {
  : > "$temp_dir/gh.log"
  : > "$temp_dir/summary.md"
  PATH="$temp_dir/bin:$PATH" GH_LOG="$temp_dir/gh.log" GITHUB_STEP_SUMMARY="$temp_dir/summary.md" \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_SERVER_URL=https://github.com "$@" bash "$report" >/dev/null
}

expect_log() {
  if ! grep -Fq -- "$1" "$temp_dir/gh.log"; then
    printf 'Expected gh call containing: %s\nGot:\n%s\n' "$1" "$(cat "$temp_dir/gh.log")" >&2
    exit 1
  fi
}

expect_no_log() {
  if grep -Fq -- "$1" "$temp_dir/gh.log"; then
    printf 'Unexpected gh call containing: %s\n' "$1" >&2
    exit 1
  fi
}

# A failing nightly with no open issue labels and opens one with the failing jobs.
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/main FAKE_FAILED_JOBS='Full suite / Android\tu\tfailure'
expect_log 'label create ci-nightly'
expect_log 'issue create --repo owner/repo --title Nightly CI failing on main --label ci-nightly'
expect_log 'Full suite / Android'
expect_log 'actions/runs/42'

# A failing nightly with an open issue updates it instead of opening a second one.
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/main FAKE_OPEN_ISSUE=7
expect_log 'issue edit 7'
expect_log 'issue comment 7'
expect_no_log 'issue create'

# A passing nightly closes the open issue, and does nothing when none is open.
run env SUITE_RESULT=success GITHUB_REF=refs/heads/main FAKE_OPEN_ISSUE=7
expect_log 'issue close 7 --repo owner/repo --reason completed'
run env SUITE_RESULT=success GITHUB_REF=refs/heads/main
expect_no_log 'issue close'

# A mirrored tracker from another repository is never this repository's issue.
run env SUITE_RESULT=success GITHUB_REF=refs/heads/main
expect_no_log 'issue close 9'
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/main
expect_no_log 'issue edit 9'
expect_log 'issue create'

# Only quarantined jobs failed: the issue closes as on a passing night; any other failure keeps it.
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/main FAKE_OPEN_ISSUE=7 \
  QUARANTINED_JOBS=$'Shared conformance scenarios, iOS\nPlayback labels' \
  FAKE_FAILED_JOBS='Full suite / Shared conformance scenarios, iOS\tu\tfailure'
expect_log 'issue close 7'
grep -Fq 'Quarantined' "$temp_dir/summary.md" || { echo 'Expected quarantined jobs in the summary.' >&2; exit 1; }
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/main FAKE_OPEN_ISSUE=7 \
  QUARANTINED_JOBS='Shared conformance scenarios, iOS' \
  FAKE_FAILED_JOBS='Full suite / Shared conformance scenarios, iOS\tu\tfailure\nFull suite / Android\tv\tfailure'
expect_log 'issue edit 7'
expect_no_log 'issue close'

# Other refs and cancelled runs leave the issue alone.
run env SUITE_RESULT=failure GITHUB_REF=refs/heads/ci/branch
expect_no_log 'issue'
run env SUITE_RESULT=cancelled GITHUB_REF=refs/heads/main FAKE_OPEN_ISSUE=7
expect_no_log 'issue close'
expect_no_log 'issue edit'

printf 'Nightly report tests passed.\n'
