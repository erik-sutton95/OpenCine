#!/usr/bin/env bash
# Builds OpenCine.app with its embedded camera driver.
set -euo pipefail
desktop="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desktop"
xcodegen generate --quiet
exec xcodebuild -project OpenCineDesktop.xcodeproj -scheme "${SCHEME:-OpenCine}" -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath "${DESKTOP_DERIVED_DATA_PATH:-$desktop/build/DerivedData}" \
  -allowProvisioningUpdates "$@" build
