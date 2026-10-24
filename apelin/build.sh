#!/bin/sh
# Apelin external build script for Lemon.
# Compiles the SpringBoard tweak and the Settings pane for the target bootstrap,
# signs both and writes one .deb into $APELIN_PACKAGE_DIR.

set -eu

PACKAGE_ID="com.lemon.ripple"
PACKAGE_NAME="Lemon"
PACKAGE_VERSION="0.1.0"
PACKAGE_AUTHOR="Lessica <82flex@gmail.com>"
TWEAK_NAME="LEMRipple"
PREFS_NAME="LemonPrefs"

ROOT="${APELIN_PROJECT_ROOT:-$(pwd)}"
SRC_DIR="$ROOT/lemon"
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

WORK_DIR="$(mktemp -d "$TMPDIR/lemon-build.XXXXXX")"
OBJ_DIR="$WORK_DIR/obj"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$OBJ_DIR" "$STAGE_DIR"

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
          -framework CoreHaptics \
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
# and defaults are shared with the tweak through LEMPreferences.m.
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
          -o "$OBJ_DIR/$PREFS_NAME-$ARCH" \
          "$PREF_SRC_DIR/LEMPrefsRootListController.m" \
          "$SRC_DIR/LEMPreferences.m"
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
cp "$SRC_DIR/$TWEAK_NAME.ahap" "$LIB_DIR/$TWEAK_NAME.ahap"
cp "$OBJ_DIR/$PREFS_NAME" "$PREFS_BUNDLE_DIR/$PREFS_NAME"
cp "$PREF_SRC_DIR/Info.plist" "$PREFS_BUNDLE_DIR/Info.plist"
cp "$PREF_SRC_DIR/Lemon.plist" "$PREFS_ENTRY_DIR/Lemon.plist"

cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Name: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Architecture: $ARCHITECTURE
Maintainer: $PACKAGE_AUTHOR
Author: $PACKAGE_AUTHOR
Section: Tweaks
Depends: firmware (>= 15.0), preferenceloader.top | preferenceloader
Description: Two-finger spread gesture for the home screen: the icons ripple outwards, every app badge is cleared and kept cleared, and a custom haptic pattern follows the ripple.
EOF

echo "==> packaging"
dpkg-deb -b --root-owner-group "$STAGE_DIR" "$PACKAGE_DIR/" >/dev/null
ls -l "$PACKAGE_DIR"

rm -rf "$WORK_DIR"
