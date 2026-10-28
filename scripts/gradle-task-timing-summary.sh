#!/usr/bin/env bash
# Summarize every Gradle timing file of a CI job (scripts/gradle-task-timing.init.gradle) into the
# job summary, and list each run's task inventory in a collapsed log group so jobs can be compared.
# Usage: gradle-task-timing-summary.sh <directory of *.tsv>. Never fails the job.
set -uo pipefail
dir="${1:?timing directory}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
for timing in "$dir"/*.tsv; do
  name="$(basename "$timing" .tsv)"
  python3 "$script_dir/gradle-task-timing-report.py" "$timing" --summary --title "Gradle task timing: $name" \
    --tasks "$dir/$name.tasks" > /dev/null || true
  echo "::group::Task inventory: $name ($(wc -l < "$dir/$name.tasks" | tr -d ' ') tasks)"
  cat "$dir/$name.tasks"
  echo "::endgroup::"
done
exit 0
