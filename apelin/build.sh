#!/bin/sh
# Apelin external build script for Fizz.
# Compiles the SpringBoard tweak and the Settings pane for the target bootstrap,
# signs both and writes one .deb into $APELIN_PACKAGE_DIR.

set -eu

PACKAGE_ID="com.fizz.ripple"
PACKAGE_NAME="Fizz"
PACKAGE_VERSION="0.1.2"
PACKAGE_AUTHOR="Lessica <82flex@gmail.com>"
TWEAK_NAME="Fizz"
PREFS_NAME="FizzPrefs"

ROOT="${APELIN_PROJECT_ROOT:-$(pwd)}"
SRC_DIR="$ROOT/fizz"
PREF_SRC_DIR="$SRC_DIR/prefs"
BUILD_ID="${APELIN_BUILD_ID:-dev}"
PACKAGE_DIR="${APELIN_PACKAGE_DIR:?APELIN_PACKAGE_DIR is required}"
ARCHITECTURE="${APELIN_ARCHITECTURE:-iphoneos-arm64e}"
PREFIX="${APELIN_PREFIX:-}"

if [ "${APELIN_BOOTSTRAP:-roothide}" = "rootless" ]; then
    ARCHS="arm64 arm64e"
else
    ARCHS="arm64e"
fi

WORK_DIR="$(mktemp -d "$TMPDIR/fizz-build.XXXXXX")"
OBJ_DIR="$WORK_DIR/obj"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$OBJ_DIR" "$STAGE_DIR"

# On a roothide bootstrap the root directory has a random name that changes on
# every reboot, so a toolchain or SDK recorded by its absolute path can be
# reported missing while its files are still on disk under the new name. Find
# them under the current root instead of asking for a reinstall.
JBROOT_PREFIX=""
if command -v jbroot >/dev/null 2>&1; then
    JBROOT_PREFIX="$(jbroot 2>/dev/null || true)"
fi

if ! command -v clang >/dev/null 2>&1; then
    for TOOLCHAIN_BIN in "${JBROOT_PREFIX}"usr/lib/apelin/toolchains/*/usr/bin; do
        if [ -x "$TOOLCHAIN_BIN/clang" ]; then
            PATH="$TOOLCHAIN_BIN:$PATH"
            break
        fi
    done
fi
if ! command -v clang >/dev/null 2>&1; then
    echo "no clang on PATH and none found under the bootstrap root"
    exit 1
fi

# Same for the sysroot: the glob is sorted by name, so the last usable SDK wins
# and a newer iPhoneOS SDK is preferred over an older one.
if [ -z "${SDKROOT:-}" ] || [ ! -d "${SDKROOT}" ]; then
    SDKROOT=""
    for CANDIDATE in "${JBROOT_PREFIX}"var/mobile/Documents/wiki.qaq.apelin/SDKs/*/; do
        if [ -d "$CANDIDATE/System/Library/Frameworks/UIKit.framework" ]; then
            SDKROOT="$CANDIDATE"
        fi
    done
    if [ -z "$SDKROOT" ]; then
        echo "no iPhoneOS SDK on this device; import one in Settings"
        exit 1
    fi
    export SDKROOT
fi

SLICES=""
for ARCH in $ARCHS; do
    echo "==> compiling $ARCH"
    OBJECTS=""
    for SOURCE in "$SRC_DIR"/*.m; do
        OBJECT="$OBJ_DIR/$(basename "$SOURCE" .m)-$ARCH.o"
        clang -arch "$ARCH" \
              -miphoneos-version-min=15.0 \
              -fobjc-arc \
              -fvisibility=hidden \
              -O2 -g -Wall \
              -I "$SRC_DIR" \
              -DAPELIN_BUILD_ID="\"$BUILD_ID\"" \
              -c "$SOURCE" \
              -o "$OBJECT"
        OBJECTS="$OBJECTS $OBJECT"
    done

    echo "==> linking $ARCH"
    # shellcheck disable=SC2086
    clang -arch "$ARCH" \
          -miphoneos-version-min=15.0 \
          -dynamiclib \
          -framework Foundation \
          -framework UIKit \
          -framework CoreGraphics \
          -framework QuartzCore \
          -o "$OBJ_DIR/$TWEAK_NAME-$ARCH.dylib" \
          $OBJECTS
    SLICES="$SLICES $OBJ_DIR/$TWEAK_NAME-$ARCH.dylib"
done

echo "==> lipo"
# shellcheck disable=SC2086
lipo -create -output "$OBJ_DIR/$TWEAK_NAME.dylib" $SLICES
lipo -info "$OBJ_DIR/$TWEAK_NAME.dylib"

echo "==> signing"
ldid -S "$OBJ_DIR/$TWEAK_NAME.dylib"

# The Settings pane is a bundle loaded into Settings.app. PSListController and
# PSSpecifier stay unresolved here and are bound when Settings loads the pane,
# so the build needs no private framework at link time. The preference domain
# and defaults are shared with the tweak through FIZZPreferences.m.
PREF_SLICES=""
for ARCH in $ARCHS; do
    echo "==> compiling preferences $ARCH"
    clang -arch "$ARCH" \
          -miphoneos-version-min=15.0 \
          -fobjc-arc \
          -fvisibility=hidden \
          -O2 -g -Wall \
          -I "$SRC_DIR" \
          -bundle -undefined dynamic_lookup \
          -framework Foundation \
          -framework UIKit \
          -framework QuartzCore \
          -framework ImageIO \
          -o "$OBJ_DIR/$PREFS_NAME-$ARCH" \
          "$PREF_SRC_DIR/FIZZPrefsRootListController.m" \
          "$SRC_DIR/FIZZPreferences.m"
    PREF_SLICES="$PREF_SLICES $OBJ_DIR/$PREFS_NAME-$ARCH"
done

echo "==> lipo preferences"
# shellcheck disable=SC2086
lipo -create -output "$OBJ_DIR/$PREFS_NAME" $PREF_SLICES
lipo -info "$OBJ_DIR/$PREFS_NAME"
ldid -S "$OBJ_DIR/$PREFS_NAME"

echo "==> staging"
LIB_DIR="$STAGE_DIR$PREFIX/Library/MobileSubstrate/DynamicLibraries"
PREFS_BUNDLE_DIR="$STAGE_DIR$PREFIX/Library/PreferenceBundles/$PREFS_NAME.bundle"
PREFS_ENTRY_DIR="$STAGE_DIR$PREFIX/Library/PreferenceLoader/Preferences"
mkdir -p "$LIB_DIR" "$STAGE_DIR/DEBIAN" "$PREFS_BUNDLE_DIR" "$PREFS_ENTRY_DIR"
cp "$OBJ_DIR/$TWEAK_NAME.dylib" "$LIB_DIR/$TWEAK_NAME.dylib"
cp "$SRC_DIR/$TWEAK_NAME.plist" "$LIB_DIR/$TWEAK_NAME.plist"
cp "$OBJ_DIR/$PREFS_NAME" "$PREFS_BUNDLE_DIR/$PREFS_NAME"
cp "$PREF_SRC_DIR/Info.plist" "$PREFS_BUNDLE_DIR/Info.plist"
cp "$PREF_SRC_DIR/icon.png" "$PREF_SRC_DIR/icon@2x.png" "$PREF_SRC_DIR/icon@3x.png" "$PREFS_BUNDLE_DIR/"
cp "$PREF_SRC_DIR/banner.png" "$PREF_SRC_DIR/banner@2x.png" "$PREF_SRC_DIR/banner@3x.png" "$PREFS_BUNDLE_DIR/"
cp "$PREF_SRC_DIR/Fizz.plist" "$PREFS_ENTRY_DIR/Fizz.plist"
for LPROJ in "$PREF_SRC_DIR"/*.lproj; do
    cp -R "$LPROJ" "$PREFS_BUNDLE_DIR/"
done

cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Name: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Architecture: $ARCHITECTURE
Maintainer: $PACKAGE_AUTHOR
Author: $PACKAGE_AUTHOR
Section: Tweaks
Depends: firmware (>= 15.0), preferenceloader.top | preferenceloader
Description: Two-finger spread gesture for the home screen: the icons ripple outwards, every app badge grows out and fades away and is kept cleared, and one system tap marks the moment they are gone.
EOF

echo "==> packaging"
dpkg-deb -b --root-owner-group "$STAGE_DIR" "$PACKAGE_DIR/" >/dev/null
ls -l "$PACKAGE_DIR"

rm -rf "$WORK_DIR"
