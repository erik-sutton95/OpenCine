#!/bin/sh
# One dependency closure: each OpenCine package resolves to exactly one checkout, however many
# packages depend on it. SwiftPM links the test binary statically, so a second copy of a module
# would also fail the link; an "implemented in both" runtime warning in `swift test` output is
# the other symptom and CI greps for it.
set -eu
cd "$(dirname "$0")/.."
paths=$(swift package show-dependencies --format json |
  sed -n 's/.*"path" *: *"\([^"]*\)".*/\1/p' | sort -u)
for name in OpenCineCore OpenCineMulticam OpenCineDJI OpenCineNikon OpenCineInsta360; do
  count=$(printf '%s\n' "$paths" | grep -c "/$name\$" || true)
  if [ "$count" != 1 ]; then
    echo "error: $name resolves to $count checkouts" >&2
    exit 1
  fi
done
echo "one checkout per package"
