#!/usr/bin/env bash
# Keep one tracking issue per repository in step with the nightly full suite on main.
# A failed nightly opens "Nightly CI failing on main" (label ci-nightly) or updates the open one
# with the failing jobs and the run link; a passing nightly closes it. Jobs named in
# QUARANTINED_JOBS (one per line, as in ci.yml) have their own ci-quarantine issues: their failures
# are listed but neither open nor keep open this issue. Other refs and cancelled runs only write
# the job summary. Shared by OpenCine and every app's nightly.yml.
#
# Env: GH_TOKEN (issues: write, actions: read), SUITE_RESULT (the full-suite job's result),
# QUARANTINED_JOBS, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_REF,
# GITHUB_SERVER_URL.
set -euo pipefail

label=ci-nightly
title="Nightly CI failing on main"
repo="$GITHUB_REPOSITORY"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
result="${SUITE_RESULT:?SUITE_RESULT is required}"

failed="$(gh api --paginate \
  "repos/${repo}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100" \
  --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")
    | [.name, .html_url, .conclusion] | @tsv')"

failed_jobs=""
quarantined_jobs=""
while IFS=$'\t' read -r name url conclusion; do
  [ -n "$name" ] || continue
  line="- [${name}](${url}): ${conclusion}"
  # A called workflow's jobs are named "<caller job> / <job>".
  if grep -Fxq -- "${name##* / }" <<< "${QUARANTINED_JOBS:-}"; then
    quarantined_jobs+="${line}"$'\n'
  else
    failed_jobs+="${line}"$'\n'
  fi
done <<< "$failed"
failed_jobs="${failed_jobs%$'\n'}"
quarantined_jobs="${quarantined_jobs%$'\n'}"

# Only quarantined jobs failed: for this issue that is a passing night.
if [ "$result" = failure ] && [ -z "$failed_jobs" ] && [ -n "$quarantined_jobs" ]; then
  result=success
fi

{
  echo "## Nightly full suite: ${result}"
  echo
  echo "${failed_jobs:-No failed jobs outside quarantine.}"
  if [ -n "$quarantined_jobs" ]; then
    echo
    echo "Quarantined (tracked by their ci-quarantine issues):"
    echo
    echo "$quarantined_jobs"
  fi
} >> "$summary"

if [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  echo "Nightly on ${GITHUB_REF:-an unknown ref}: the tracking issue follows main only."
  exit 0
fi

# Match the exact title: linked-issue sync mirrors other repositories' trackers here with the same
# label and a "[Repo#n] " prefix, and those belong to their own repository's nightly.
open_issue="$(gh issue list --repo "$repo" --label "$label" --state open --json number,title \
  --jq "[.[] | select(.title == \"$title\")][0].number // empty")"

case "$result" in
  success)
    if [ -n "$open_issue" ]; then
      gh issue close "$open_issue" --repo "$repo" --reason completed \
        --comment "The nightly full suite passed on main: ${run_url}"
      echo "Closed #${open_issue}: the nightly passed."
    fi
    ;;
  failure)
    sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    body="$(printf '%s\n' \
      "The nightly full suite failed on \`main\` at ${sha}: ${run_url}" \
      "" \
      "Failing jobs:" \
      "" \
      "${failed_jobs:-- (no job reported a failure; see the run)}" \
      "" \
      "This issue is updated by every failing nightly and closed by the first passing one." \
      "Tiers and quarantine: docs/testing/CI.md in OpenCine, the CI doc in each app.")"
    if [ -n "$open_issue" ]; then
      gh issue edit "$open_issue" --repo "$repo" --body "$body"
      gh issue comment "$open_issue" --repo "$repo" --body "Still failing: ${run_url}"
      echo "Updated #${open_issue}."
    else
      gh label create "$label" --repo "$repo" --color B60205 \
        --description "Nightly full suite on main is failing" 2>/dev/null || true
      gh issue create --repo "$repo" --title "$title" --label "$label" --body "$body"
    fi
    ;;
  *)
    echo "Nightly suite result '${result}': the tracking issue is unchanged."
    ;;
esac
