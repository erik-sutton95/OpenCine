#!/bin/sh
# SHELL-05 end-to-end check of the new-app template. SIMULATED: no camera, no hardware.
# Generates a thin app next to this OpenCine checkout (`atlas new-app`), then
#   ios:     builds the shipping and SIMULATED targets (generic iOS Simulator), runs the SIMULATED
#            contract test on a private simulator, launches the SIMULATED app there and saves a
#            screenshot of the shared shell with the fake camera (ios-simulated.png);
#   android: runs the app's unit tests and lint, assembles the SIMULATED debug and shipping release.
# Usage: scripts/template-app-check.sh [ios|android|all]   (default all)
# Env: NAME (default OpenTemplateCheck), OUT (logs and screenshot, default $TMPDIR/template-app-check),
#      KEEP=1 keeps the generated app. Android needs JAVA_HOME (17 or newer) and ANDROID_HOME.
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
what=${1:-all}
name=${NAME:-OpenTemplateCheck}
id=com.opencapture.$(echo "$name" | tr '[:upper:]' '[:lower:]')
app="$(dirname "$top")/$name"
out=${OUT:-${TMPDIR:-/tmp}/template-app-check}
udid=
mkdir -p "$out"

cleanup() {
  [ -z "$udid" ] || xcrun simctl delete "$udid"
  [ "${KEEP:-0}" = 1 ] || rm -rf "$app"
}
step() { # step <log> <command...>: quiet unless it fails
  log=$1; shift
  if "$@" > "$out/$log" 2>&1; then echo "ok   $log"; else tail -40 "$out/$log"; echo "FAIL $log" >&2; exit 1; fi
}

python3 "$top/atlas/tools/atlas.py" new-app "$name"
trap cleanup EXIT

if [ "$what" != android ]; then
  (cd "$app/ios" && xcodegen generate --quiet)
  project="$app/ios/$name.xcodeproj"
  dd="$out/DerivedData"
  for scheme in "$name" "${name}Simulated"; do
    step "ios-build-$scheme.log" xcodebuild -project "$project" -scheme "$scheme" \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" -jobs 4 build
  done
  udid=$(xcrun simctl create "opc-$name" "iPhone 16 Pro")
  step ios-contract-test.log xcodebuild -project "$project" -scheme "${name}Simulated" \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd" -jobs 4 test
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl install "$udid" "$dd/Build/Products/Debug-iphonesimulator/${name}Simulated.app"
  xcrun simctl launch "$udid" "$id.simulated" > /dev/null
  # ponytail: a fixed wait for the first frames; poll the screenshot if this ever flakes.
  sleep 8
  xcrun simctl io "$udid" screenshot "$out/ios-simulated.png" > /dev/null 2>&1
  echo "ok   ios-simulated.png ($out)"
fi

if [ "$what" != ios ]; then
  step android.log sh -c "cd '$app/Android' && ./gradlew --max-workers 4 test lint assembleSimulatedDebug assembleCameraRelease"
fi
