#!/usr/bin/env bash
# Fails when a shrunk Android package ships a Firebase ComponentRegistrar without its no-argument
# constructor. ML Kit discovers its registrars by class name and instantiates them reflectively;
# R8 full mode keeps the names (firebase-components consumer rule) but may strip the constructors,
# and then ML Kit never initializes (OPENPOCKETCINE-ANDROID-18: NPE on the first face frame).
# Usage: android-verify-component-registrars.sh <apk-or-aab>...
# Needs dexdump from the Android SDK build tools (ANDROID_HOME, ANDROID_SDK_ROOT or DEXDUMP).
set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ $# -gt 0 ]] || fail "usage: $(basename "$0") <apk-or-aab>..."
dexdump="${DEXDUMP:-}"
if [[ -z "$dexdump" ]]; then
    sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    [[ -n "$sdk_root" ]] || fail "set ANDROID_HOME, ANDROID_SDK_ROOT or DEXDUMP"
    dexdump="$(find "$sdk_root/build-tools" -maxdepth 2 -name dexdump -type f 2>/dev/null | sort -V | tail -n 1)"
fi
[[ -n "$dexdump" && -x "$dexdump" ]] || fail "dexdump not found in the Android SDK build tools"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/opc-registrars.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

for archive in "$@"; do
    [[ -f "$archive" ]] || fail "missing package: $archive"
    rm -rf "${scratch:?}"/*
    # APK dex sits at the root, AAB dex under base/dex/.
    unzip -q -j "$archive" 'classes*.dex' 'base/dex/classes*.dex' -d "$scratch" 2>/dev/null || true
    dex_files=("$scratch"/*.dex)
    [[ -f "${dex_files[0]}" ]] || fail "no dex files in $archive"
    for dex in "${dex_files[@]}"; do "$dexdump" "$dex"; done > "$scratch/dump.txt" 2>/dev/null
    # One line per registrar class: "<descriptor> <1 when it has ()V <init>, else 0>".
    awk '
        function flush() { if (cls != "" && registrar) print cls, init; cls = ""; registrar = 0; init = 0 }
        /^  Class descriptor  : / { flush(); cls = $4; gsub("\047", "", cls); section = ""; next }
        /^  Interfaces        -/ { section = "interfaces"; next }
        /^  (Static fields|Instance fields|Virtual methods)/ { section = ""; next }
        /^  Direct methods    -/ { section = "direct"; next }
        section == "interfaces" && index($0, "\047Lcom/google/firebase/components/ComponentRegistrar;\047") { registrar = 1 }
        section == "direct" && /^      name          : / { constructor = ($3 == "\047<init>\047") }
        section == "direct" && constructor && /^      type          : / { if ($3 == "\047()V\047") init = 1; constructor = 0 }
        END { flush() }
    ' "$scratch/dump.txt" > "$scratch/registrars.txt"
    [[ -s "$scratch/registrars.txt" ]] || fail "$archive has no ComponentRegistrar classes to verify"
    if awk '$2 == 0 { print "  " $1; missing = 1 } END { exit !missing }' "$scratch/registrars.txt" > "$scratch/missing.txt"; then
        printf 'error: %s strips the no-argument constructor of these ComponentRegistrar classes:\n' "$archive" >&2
        cat "$scratch/missing.txt" >&2
        fail "keep them: -keep class * implements com.google.firebase.components.ComponentRegistrar { *; }"
    fi
    printf 'Verified %s ComponentRegistrar constructors in %s\n' "$(wc -l < "$scratch/registrars.txt" | tr -d ' ')" "$archive"
done
