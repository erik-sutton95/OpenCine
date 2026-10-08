#!/bin/sh
# SHELL-05: generate fresh primary/companion apps, then run their actual full SIMULATED acceptance.
# Usage: scripts/template-app-check.sh [ios|android|all]
# Env: NAME, OUT, KEEP=1. Android requires an explicit ANDROID_SERIAL or TEMPLATE_EMULATOR=1.
# The generated check script records raw reports, native screenshots, source and binary hashes.
set -eu
template_top=$(cd "$(dirname "$0")/.." && pwd)
template_platform=${1:-all}
template_name=${NAME:-OpenTemplateCheck}
template_app="$(dirname "$template_top")/$template_name"
template_out=${OUT:-${TMPDIR:-/tmp}/template-app-check-$(date -u +%Y%m%dT%H%M%SZ)}
case "$template_platform" in ios|android|all) ;; *) echo 'Expected ios, android or all' >&2; exit 2 ;; esac
mkdir -p "$template_out"
python3 "$template_top/atlas/tools/atlas.py" new-app "$template_name" --integration fake > "$template_out/generate.log"
template_cleanup() { [ "${KEEP:-0}" = 1 ] || rm -rf "$template_app"; }
trap template_cleanup EXIT
trap 'exit 130' HUP INT TERM
OUT="$template_out/acceptance" sh "$template_app/scripts/check-simulated.sh" "$template_platform"
