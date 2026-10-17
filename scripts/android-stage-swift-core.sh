#!/usr/bin/env bash
# Cross-compiles one app's Swift Android product and stages its dynamic-library
# closure. Pass --product with that app's Swift package product name.
#
# This is deliberately a build input, not a source-tree artifact: Gradle passes
# a directory under app/build/generated/, so a clean checkout cannot
# accidentally package an ignored, stale src/main/jniLibs/ directory.
set -euo pipefail

readonly SWIFT_VERSION="6.3.3"
readonly DEFAULT_SWIFT_SDK="swift-6.3.3-RELEASE_android"
readonly DEFAULT_TARGET="aarch64-unknown-linux-android29"

usage() {
    cat <<'EOF'
Usage: android-stage-swift-core.sh --product <Swift-product> --output <jniLibs-directory>

Environment overrides:
  SWIFT_EXECUTABLE       Path to the matching Swift 6.3.3 binary.
  SWIFT_ANDROID_SDK_ID   Installed Swift SDK ID (default: swift-6.3.3-RELEASE_android).
  SWIFT_ANDROID_TARGET   Swift target triple (default: aarch64-unknown-linux-android29).

The target is intentionally arm64-only: Android ABI name arm64-v8a.
Run this from the app root, the directory that contains Package.swift.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

output=""
product_name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || fail "--output needs a directory"
            output="$2"
            shift 2
            ;;
        --product)
            [[ $# -ge 2 ]] || fail "--product needs a Swift product name"
            product_name="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$output" ]] || {
    usage >&2
    fail "--output is required"
}
[[ "$product_name" =~ ^[A-Za-z][A-Za-z0-9]+$ ]] || fail "--product must be a Swift product name"
PRODUCT="$product_name"

# The app wrapper and Gradle start this in the app root. Do not change into
# the OpenCine checkout: that package does not contain the app product.
if [[ ! -f Package.swift ]]; then
    fail "run this from the app root that contains Package.swift"
fi

if [[ -n "${SWIFT_EXECUTABLE:-}" ]]; then
    swift="$SWIFT_EXECUTABLE"
elif [[ -x "${SWIFT_INSTALLATION:-}/bin/swift" ]]; then
    # skiptools/swift-android-action exports the installed host toolchain through
    # GITHUB_ENV as SWIFT_INSTALLATION. Prefer it to the runner's system Swift:
    # the Android SDK must be driven by its exact matching host toolchain.
    swift="$SWIFT_INSTALLATION/bin/swift"
elif [[ -x "$HOME/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain/usr/bin/swift" ]]; then
    # Swiftly puts the requested macOS release toolchain here.
    swift="$HOME/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain/usr/bin/swift"
else
    swift="$(command -v swift || true)"
fi

[[ -n "$swift" && -x "$swift" ]] || fail \
    "Swift ${SWIFT_VERSION} was not found; set SWIFT_EXECUTABLE to that toolchain's swift binary"

swift_version="$($swift --version)"
[[ "$swift_version" == *"${SWIFT_VERSION}"* ]] || fail \
    "Swift ${SWIFT_VERSION} is required by the Android SDK; found: ${swift_version%%$'\n'*}"

toolchain_bin="$(cd "$(dirname "$swift")" && pwd -P)"
objcopy="$toolchain_bin/llvm-objcopy"
objdump="$toolchain_bin/llvm-objdump"
[[ -x "$objcopy" ]] || fail "llvm-objcopy is missing beside $swift"
[[ -x "$objdump" ]] || fail "llvm-objdump is missing beside $swift"

sdk_id="${SWIFT_ANDROID_SDK_ID:-$DEFAULT_SWIFT_SDK}"
target="${SWIFT_ANDROID_TARGET:-$DEFAULT_TARGET}"
case "$target" in
    aarch64-unknown-linux-android*) ;;
    *) fail "this app currently ships only arm64-v8a; refusing target $target" ;;
esac

sdk_configuration="$($swift sdk configure --show-configuration "$sdk_id" "$target")" || fail \
    "Swift Android SDK $sdk_id is not configured for $target"
sdk_root="$(printf '%s\n' "$sdk_configuration" | awk -F': ' '/^sdkRootPath:/{print $2; exit}')"
swift_resources="$(printf '%s\n' "$sdk_configuration" | awk -F': ' '/^swiftResourcesPath:/{print $2; exit}')"
[[ -d "$sdk_root" ]] || fail "Swift SDK root is missing: $sdk_root"
[[ -d "$swift_resources/android" ]] || fail "Swift runtime is missing: $swift_resources/android"

runtime="$swift_resources/android"
ndk_libraries="$sdk_root/usr/lib/aarch64-linux-android"
[[ -d "$ndk_libraries" ]] || fail "Android NDK libraries are missing: $ndk_libraries"

# Optional caller-owned SwiftPM paths keep resource routing outside product configuration.
# An unset root preserves the toolchain's existing defaults exactly.
swift_build() {
    if [[ -n "${OPENCINE_SWIFTPM_PATHS_ROOT:-}" ]]; then
        "$swift" build --cache-path "$OPENCINE_SWIFTPM_PATHS_ROOT/cache" \
            --config-path "$OPENCINE_SWIFTPM_PATHS_ROOT/config" \
            --security-path "$OPENCINE_SWIFTPM_PATHS_ROOT/security" "$@"
    else
        "$swift" build "$@"
    fi
}

swift_build --swift-sdk "$target" -c release --product "$PRODUCT"
build_directory="$(swift_build --swift-sdk "$target" -c release --show-bin-path)"
product="$build_directory/lib${PRODUCT}.so"
[[ -f "$product" ]] || fail "Swift product was not built: $product"

output="$(mkdir -p "$output" && cd "$output" && pwd -P)"
temporary_output="${output}.staging.$$"
rm -rf "$temporary_output"
mkdir -p "$temporary_output"
trap 'rm -rf "$temporary_output"' EXIT

"$objcopy" --strip-all "$product" "$temporary_output/lib${PRODUCT}.so"

# Copy the dynamic-library closure. Dependencies not present in the Swift
# runtime or NDK sysroot must be bionic system libraries; keep the allowlist
# narrow so a new Swift runtime dependency cannot silently ship broken.
is_android_system_library() {
    case "$1" in
        libc.so|libdl.so|liblog.so|libm.so|libz.so) return 0 ;;
        *) return 1 ;;
    esac
}

changed=1
while [[ "$changed" == 1 ]]; do
    changed=0
    for library in "$temporary_output"/*.so; do
        [[ -f "$library" ]] || continue
        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            [[ -f "$temporary_output/$dependency" ]] && continue
            if [[ -f "$runtime/$dependency" ]]; then
                cp "$runtime/$dependency" "$temporary_output/$dependency"
                changed=1
            elif [[ -f "$ndk_libraries/$dependency" ]]; then
                cp "$ndk_libraries/$dependency" "$temporary_output/$dependency"
                changed=1
            elif ! is_android_system_library "$dependency"; then
                fail "unresolved non-system dependency $dependency required by $(basename "$library")"
            fi
        done < <("$objdump" -p "$library" | awk '/NEEDED/{print $2}')
    done
done

[[ -s "$temporary_output/lib${PRODUCT}.so" ]] || fail "staged core library is missing"

# Build a stable manifest used by the final APK/AAB verifier. It intentionally
# records every .so in the closure rather than a hand-maintained subset.
find "$temporary_output" -maxdepth 1 -type f -name '*.so' -exec basename {} \; | LC_ALL=C sort \
    > "$temporary_output/native-libraries.txt"
[[ -s "$temporary_output/native-libraries.txt" ]] || fail "Swift runtime closure is empty"

rm -rf "$output"
mv "$temporary_output" "$output"
trap - EXIT

# The shipped library is stripped; keep the unstripped one (same GNU build-id, with DWARF) beside
# jniLibs so the release upload (scripts/sentry/sentry-upload.py) can symbolicate Swift frames.
if [[ "$output" == */jniLibs/* ]]; then
    symbols="${output%/jniLibs/*}/symbols/${output##*/}"
    mkdir -p "$symbols"
    cp "$product" "$symbols/lib${PRODUCT}.so"
fi

printf 'Staged %s native libraries for arm64-v8a → %s\n' \
    "$(wc -l < "$output/native-libraries.txt" | tr -d ' ')" "$output"
