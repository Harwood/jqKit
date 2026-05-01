#!/usr/bin/env bash
# build-xcframeworks.sh
# Compiles jq and oniguruma from source for all relevant Apple platform/arch
# combinations and packages them as XCFrameworks in ../Frameworks/.
#
# Prerequisites:
#   brew install automake autoconf libtool
#   Xcode 15+ with command-line tools selected
#
# Usage:
#   ./scripts/build-xcframeworks.sh               # uses defaults below
#   ./scripts/build-xcframeworks.sh 1.8.1 6.9.9   # explicit versions
#
# After running, Frameworks/ will contain:
#   Cjq.xcframework       — libjq static library
#   Coniguruma.xcframework — liboniguruma static library
#
# To produce a release, zip each framework and record the SHA-256 checksums:
#   (cd Frameworks && zip -r ../Cjq.xcframework.zip Cjq.xcframework)
#   (cd Frameworks && zip -r ../Coniguruma.xcframework.zip Coniguruma.xcframework)
#   shasum -a 256 *.zip
# Then update Package.swift to use the URL+checksum form.

set -euo pipefail

JQ_VERSION="${1:-1.8.1}"
ONIGURUMA_VERSION="${2:-6.9.9}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build-xcfw"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"

JQ_SRC="$BUILD_DIR/jq-$JQ_VERSION"
ONIG_SRC="$BUILD_DIR/oniguruma-$ONIGURUMA_VERSION"

MACOS_MIN="13.0"
IOS_MIN="16.0"
VISIONOS_MIN="1.0"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "▸ $*"; }

download_jq() {
    local url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${JQ_VERSION}.tar.gz"
    log "Downloading jq $JQ_VERSION"
    mkdir -p "$BUILD_DIR"
    curl -fsSL "$url" | tar xz -C "$BUILD_DIR"
}

download_oniguruma() {
    local url="https://github.com/kkos/oniguruma/releases/download/v${ONIGURUMA_VERSION}/onig-${ONIGURUMA_VERSION}.tar.gz"
    log "Downloading oniguruma $ONIGURUMA_VERSION"
    mkdir -p "$BUILD_DIR"
    curl -fsSL "$url" | tar xz -C "$BUILD_DIR"
    mv "$BUILD_DIR/onig-$ONIGURUMA_VERSION" "$ONIG_SRC" 2>/dev/null || true
}

# Builds oniguruma for one platform/arch combo.
# Args: output_dir sdk target extra_cflags
build_oniguruma() {
    local out="$1" sdk="$2" target="$3" extra_cflags="${4:-}"
    log "  oniguruma → $target"
    local work="$BUILD_DIR/onig-build/$target"
    rm -rf "$work" && mkdir -p "$work"
    (
        cd "$ONIG_SRC"
        [ -f configure ] || autoreconf -fi
        cd "$work"
        "$ONIG_SRC/configure" \
            --host="$(echo "$target" | sed 's/-apple-.*//')-apple-darwin" \
            --prefix="$out" \
            --disable-shared --enable-static \
            CC="$(xcrun -f clang)" \
            CFLAGS="-target $target -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $extra_cflags" \
            LDFLAGS="-target $target"
        make -j"$(sysctl -n hw.logicalcpu)" install
    )
}

# Builds jq for one platform/arch combo (against a pre-built oniguruma).
# Args: output_dir sdk target onig_prefix extra_cflags
build_jq() {
    local out="$1" sdk="$2" target="$3" onig_prefix="$4" extra_cflags="${5:-}"
    log "  jq → $target"
    local work="$BUILD_DIR/jq-build/$target"
    rm -rf "$work" && mkdir -p "$work"
    (
        cd "$JQ_SRC"
        [ -f configure ] || autoreconf -fi
        cd "$work"
        PKG_CONFIG_PATH="$onig_prefix/lib/pkgconfig" \
        "$JQ_SRC/configure" \
            --host="$(echo "$target" | sed 's/-apple-.*//')-apple-darwin" \
            --prefix="$out" \
            --disable-shared --enable-static \
            --disable-maintainer-mode \
            --with-oniguruma="$onig_prefix" \
            --without-oniguruma-source \
            CC="$(xcrun -f clang)" \
            CFLAGS="-target $target -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) \
                    -I$onig_prefix/include $extra_cflags" \
            LDFLAGS="-target $target -L$onig_prefix/lib"
        make -j"$(sysctl -n hw.logicalcpu)" install
    )
}

# Creates a fat library from multiple arch slices.
# Args: output_lib [input_libs...]
lipo_create() {
    local out="$1"; shift
    lipo -create "$@" -output "$out"
}

# Creates an XCFramework containing one or more platform slices.
# Each argument after the output path is a "lib headers" pair.
make_xcframework() {
    local framework_path="$1"; shift
    rm -rf "$framework_path"
    local args=()
    while [[ $# -gt 0 ]]; do
        args+=(-library "$1" -headers "$2")
        shift 2
    done
    xcodebuild -create-xcframework "${args[@]}" -output "$framework_path"
}

# ── Build targets ─────────────────────────────────────────────────────────────
# For each platform we build per-arch, then lipo into fat slices, then
# assemble into an XCFramework.

build_all() {
    [ -d "$JQ_SRC" ]   || download_jq
    [ -d "$ONIG_SRC" ] || download_oniguruma

    mkdir -p "$FRAMEWORKS_DIR"

    # ── macOS ──────────────────────────────────────────────────────────────────
    local mac_arm_onig="$BUILD_DIR/install/mac-arm64/onig"
    local mac_x86_onig="$BUILD_DIR/install/mac-x86_64/onig"
    local mac_arm_jq="$BUILD_DIR/install/mac-arm64/jq"
    local mac_x86_jq="$BUILD_DIR/install/mac-x86_64/jq"
    local mac_fat_dir="$BUILD_DIR/fat/mac"

    build_oniguruma "$mac_arm_onig" macosx "arm64-apple-macos$MACOS_MIN"
    build_oniguruma "$mac_x86_onig" macosx "x86_64-apple-macos$MACOS_MIN"
    build_jq "$mac_arm_jq" macosx "arm64-apple-macos$MACOS_MIN"  "$mac_arm_onig"
    build_jq "$mac_x86_jq" macosx "x86_64-apple-macos$MACOS_MIN" "$mac_x86_onig"

    mkdir -p "$mac_fat_dir"
    lipo_create "$mac_fat_dir/libonig.a"  "$mac_arm_onig/lib/libonig.a" "$mac_x86_onig/lib/libonig.a"
    lipo_create "$mac_fat_dir/libjq.a"   "$mac_arm_jq/lib/libjq.a"     "$mac_x86_jq/lib/libjq.a"

    # ── iOS device ─────────────────────────────────────────────────────────────
    local ios_arm_onig="$BUILD_DIR/install/ios-arm64/onig"
    local ios_arm_jq="$BUILD_DIR/install/ios-arm64/jq"

    build_oniguruma "$ios_arm_onig" iphoneos "arm64-apple-ios$IOS_MIN"
    build_jq "$ios_arm_jq" iphoneos "arm64-apple-ios$IOS_MIN" "$ios_arm_onig"

    # ── iOS simulator (arm64 + x86_64) ────────────────────────────────────────
    local iosim_arm_onig="$BUILD_DIR/install/iosim-arm64/onig"
    local iosim_x86_onig="$BUILD_DIR/install/iosim-x86_64/onig"
    local iosim_arm_jq="$BUILD_DIR/install/iosim-arm64/jq"
    local iosim_x86_jq="$BUILD_DIR/install/iosim-x86_64/jq"
    local iosim_fat_dir="$BUILD_DIR/fat/iosim"

    build_oniguruma "$iosim_arm_onig" iphonesimulator "arm64-apple-ios${IOS_MIN}-simulator"
    build_oniguruma "$iosim_x86_onig" iphonesimulator "x86_64-apple-ios${IOS_MIN}-simulator"
    build_jq "$iosim_arm_jq" iphonesimulator "arm64-apple-ios${IOS_MIN}-simulator"  "$iosim_arm_onig"
    build_jq "$iosim_x86_jq" iphonesimulator "x86_64-apple-ios${IOS_MIN}-simulator" "$iosim_x86_onig"

    mkdir -p "$iosim_fat_dir"
    lipo_create "$iosim_fat_dir/libonig.a" "$iosim_arm_onig/lib/libonig.a" "$iosim_x86_onig/lib/libonig.a"
    lipo_create "$iosim_fat_dir/libjq.a"  "$iosim_arm_jq/lib/libjq.a"     "$iosim_x86_jq/lib/libjq.a"

    # ── Mac Catalyst ───────────────────────────────────────────────────────────
    local cat_arm_onig="$BUILD_DIR/install/cat-arm64/onig"
    local cat_x86_onig="$BUILD_DIR/install/cat-x86_64/onig"
    local cat_arm_jq="$BUILD_DIR/install/cat-arm64/jq"
    local cat_x86_jq="$BUILD_DIR/install/cat-x86_64/jq"
    local cat_fat_dir="$BUILD_DIR/fat/catalyst"
    local cat_extra="-target-variant arm64-apple-ios${IOS_MIN}-macabi"

    build_oniguruma "$cat_arm_onig" macosx "arm64-apple-ios${IOS_MIN}-macabi"
    build_oniguruma "$cat_x86_onig" macosx "x86_64-apple-ios${IOS_MIN}-macabi"
    build_jq "$cat_arm_jq" macosx "arm64-apple-ios${IOS_MIN}-macabi"  "$cat_arm_onig"
    build_jq "$cat_x86_jq" macosx "x86_64-apple-ios${IOS_MIN}-macabi" "$cat_x86_onig"

    mkdir -p "$cat_fat_dir"
    lipo_create "$cat_fat_dir/libonig.a" "$cat_arm_onig/lib/libonig.a" "$cat_x86_onig/lib/libonig.a"
    lipo_create "$cat_fat_dir/libjq.a"  "$cat_arm_jq/lib/libjq.a"     "$cat_x86_jq/lib/libjq.a"

    # ── visionOS device ────────────────────────────────────────────────────────
    local vos_arm_onig="$BUILD_DIR/install/visionos-arm64/onig"
    local vos_arm_jq="$BUILD_DIR/install/visionos-arm64/jq"

    build_oniguruma "$vos_arm_onig" xros "arm64-apple-xros$VISIONOS_MIN"
    build_jq "$vos_arm_jq" xros "arm64-apple-xros$VISIONOS_MIN" "$vos_arm_onig"

    # ── visionOS simulator (arm64 + x86_64) ───────────────────────────────────
    local vossim_arm_onig="$BUILD_DIR/install/vossim-arm64/onig"
    local vossim_x86_onig="$BUILD_DIR/install/vossim-x86_64/onig"
    local vossim_arm_jq="$BUILD_DIR/install/vossim-arm64/jq"
    local vossim_x86_jq="$BUILD_DIR/install/vossim-x86_64/jq"
    local vossim_fat_dir="$BUILD_DIR/fat/vossim"

    build_oniguruma "$vossim_arm_onig" xrsimulator "arm64-apple-xros${VISIONOS_MIN}-simulator"
    build_oniguruma "$vossim_x86_onig" xrsimulator "x86_64-apple-xros${VISIONOS_MIN}-simulator"
    build_jq "$vossim_arm_jq" xrsimulator "arm64-apple-xros${VISIONOS_MIN}-simulator"  "$vossim_arm_onig"
    build_jq "$vossim_x86_jq" xrsimulator "x86_64-apple-xros${VISIONOS_MIN}-simulator" "$vossim_x86_onig"

    mkdir -p "$vossim_fat_dir"
    lipo_create "$vossim_fat_dir/libonig.a" "$vossim_arm_onig/lib/libonig.a" "$vossim_x86_onig/lib/libonig.a"
    lipo_create "$vossim_fat_dir/libjq.a"  "$vossim_arm_jq/lib/libjq.a"     "$vossim_x86_jq/lib/libjq.a"

    # ── Assemble XCFrameworks ──────────────────────────────────────────────────
    # Use the macOS headers as the canonical include directory.
    local headers_jq="$mac_arm_jq/include"
    local headers_onig="$mac_arm_onig/include"

    log "Generating module map for Cjq"

    # Cjq module map (libjq)
    if [ ! -f "$headers_jq/jq.h" ]; then
        log "Error: jq.h not found in $headers_jq"
        exit 1
    fi
    cat > "$headers_jq/module.modulemap" << 'EOF'
module Cjq {
    header "jq.h"
    export *
}
EOF

    # Coniguruma is a link-only dependency for Cjq. Do not emit a module map
    # here: Xcode flattens static XCFramework headers into one product include
    # directory, so multiple Headers/module.modulemap files collide.
    if [ ! -f "$headers_onig/oniguruma.h" ]; then
        log "Error: oniguruma.h not found in $headers_onig"
        exit 1
    fi
    rm -f "$headers_onig/module.modulemap"

    log "Assembling Cjq.xcframework"
    make_xcframework "$FRAMEWORKS_DIR/Cjq.xcframework" \
        "$mac_fat_dir/libjq.a"          "$headers_jq" \
        "$ios_arm_jq/lib/libjq.a"       "$headers_jq" \
        "$iosim_fat_dir/libjq.a"        "$headers_jq" \
        "$cat_fat_dir/libjq.a"          "$headers_jq" \
        "$vos_arm_jq/lib/libjq.a"       "$headers_jq" \
        "$vossim_fat_dir/libjq.a"       "$headers_jq"

    log "Assembling Coniguruma.xcframework"
    make_xcframework "$FRAMEWORKS_DIR/Coniguruma.xcframework" \
        "$mac_fat_dir/libonig.a"        "$headers_onig" \
        "$ios_arm_onig/lib/libonig.a"   "$headers_onig" \
        "$iosim_fat_dir/libonig.a"      "$headers_onig" \
        "$cat_fat_dir/libonig.a"        "$headers_onig" \
        "$vos_arm_onig/lib/libonig.a"   "$headers_onig" \
        "$vossim_fat_dir/libonig.a"     "$headers_onig"

    log ""
    log "✓ Built jq $JQ_VERSION + oniguruma $ONIGURUMA_VERSION"
    log "  Frameworks/ contains Cjq.xcframework and Coniguruma.xcframework"
    log ""
    log "To produce a release:"
    log "  cd Frameworks"
    log "  zip -r ../Cjq.xcframework.zip Cjq.xcframework"
    log "  zip -r ../Coniguruma.xcframework.zip Coniguruma.xcframework"
    log "  shasum -a 256 ../*.xcframework.zip"
}

build_all
