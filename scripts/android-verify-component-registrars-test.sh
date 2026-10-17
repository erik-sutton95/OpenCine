#!/usr/bin/env bash
# Regression tests for android-verify-component-registrars.sh over dexdump-shaped fixtures.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="${script_dir}/android-verify-component-registrars.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# dexdump stand-in: prints the fixture named by FIXTURE for every dex file.
printf '#!/bin/sh\ncat "$FIXTURE"\n' > "${temp_dir}/dexdump"
chmod +x "${temp_dir}/dexdump"
export DEXDUMP="${temp_dir}/dexdump"

mkdir -p "${temp_dir}/apk" "${temp_dir}/aab/base/dex"
: > "${temp_dir}/apk/classes.dex"
: > "${temp_dir}/aab/base/dex/classes.dex"
(cd "${temp_dir}/apk" && zip -q ../app.apk classes.dex)
(cd "${temp_dir}/aab" && zip -q ../app.aab base/dex/classes.dex)

registrar() { # <descriptor> <direct method name> <type>
  cat <<EOF
  Class descriptor  : '$1'
  Access flags      : 0x0001 (PUBLIC)
  Superclass        : 'Ljava/lang/Object;'
  Interfaces        -
    #0              : 'Lcom/google/firebase/components/ComponentRegistrar;'
  Static fields     -
  Instance fields   -
  Direct methods    -
    #0              : (in $1)
      name          : '$2'
      type          : '$3'
      access        : 0x10001 (PUBLIC CONSTRUCTOR)
  Virtual methods   -
    #0              : (in $1)
      name          : 'a'
      type          : '()Ljava/util/List;'
EOF
}
other_class() {
  cat <<'EOF'
  Class descriptor  : 'Lcom/example/Plain;'
  Access flags      : 0x0001 (PUBLIC)
  Superclass        : 'Ljava/lang/Object;'
  Interfaces        -
  Static fields     -
  Instance fields   -
  Direct methods    -
  Virtual methods   -
EOF
}

{ other_class; registrar 'Lcom/google/mlkit/vision/face/internal/FaceRegistrar;' '<init>' '()V'; } > "${temp_dir}/kept.txt"
{ registrar 'Lcom/google/mlkit/vision/face/internal/FaceRegistrar;' '<init>' '()V'
  # Stripped: only a static helper survives, and an <init> with arguments does not count.
  registrar 'Lcom/google/mlkit/common/internal/CommonComponentRegistrar;' 'zza' '()V'
  registrar 'Lcom/google/mlkit/vision/common/internal/VisionCommonRegistrar;' '<init>' '(I)V'; } > "${temp_dir}/stripped.txt"
other_class > "${temp_dir}/none.txt"

for archive in app.apk app.aab; do
  FIXTURE="${temp_dir}/kept.txt" "$verifier" "${temp_dir}/${archive}" >/dev/null
  if FIXTURE="${temp_dir}/stripped.txt" "$verifier" "${temp_dir}/${archive}" > /dev/null 2> "${temp_dir}/err.txt"; then
    printf 'Expected stripped registrar constructors to fail: %s\n' "$archive" >&2
    exit 1
  fi
  grep -q 'CommonComponentRegistrar' "${temp_dir}/err.txt"
  grep -q 'VisionCommonRegistrar' "${temp_dir}/err.txt"
  if grep -q 'FaceRegistrar' "${temp_dir}/err.txt"; then
    printf 'A kept constructor was reported as stripped: %s\n' "$archive" >&2
    exit 1
  fi
  # A package without registrars means the check would prove nothing.
  if FIXTURE="${temp_dir}/none.txt" "$verifier" "${temp_dir}/${archive}" >/dev/null 2>&1; then
    printf 'Expected a package without registrars to fail: %s\n' "$archive" >&2
    exit 1
  fi
done
printf 'android-verify-component-registrars: ok\n'
