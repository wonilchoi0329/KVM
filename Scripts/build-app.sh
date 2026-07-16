#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}
BUILD_ROOT="$ROOT/build"
DIST_ROOT="$ROOT/dist"
APP="$DIST_ROOT/HostHop.app"
ARCHIVE="$DIST_ROOT/HostHop-arm64.zip"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "HostHop is intentionally arm64-only; build it on Apple Silicon."
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$DIST_ROOT"

export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export XDG_CACHE_HOME="$BUILD_ROOT/cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$XDG_CACHE_HOME"

swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --product HostHop

SWIFT_BIN_PATH=$(swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --product HostHop \
    --show-bin-path)

rm -rf "$APP"
mkdir -p "$MACOS"

/usr/bin/ditto "$SWIFT_BIN_PATH/HostHop" "$MACOS/HostHop"
/usr/bin/ditto "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

xcrun strip -x "$MACOS/HostHop"

# SwiftPM may emit development-only fallback rpaths. HostHop has no bundled
# libraries, so retain only the system Swift runtime path.
while IFS= read -r RPATH; do
    if [[ "$RPATH" != "/usr/lib/swift" ]]; then
        /usr/bin/install_name_tool -delete_rpath "$RPATH" "$MACOS/HostHop"
    fi
done < <(/usr/bin/otool -l "$MACOS/HostHop" | /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')

/usr/bin/codesign --force --sign - --options runtime,library --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

print "Built $APP"
/usr/bin/du -sh "$APP"
/usr/bin/shasum -a 256 "$ARCHIVE"
