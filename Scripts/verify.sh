#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/dist/HostHop.app"
ARCHIVE="$ROOT/dist/HostHop-arm64.zip"
EXECUTABLE="$APP/Contents/MacOS/HostHop"

export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/ModuleCache"
export XDG_CACHE_HOME="$ROOT/build/cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$XDG_CACHE_HOME"

swift test --package-path "$ROOT" --arch arm64
"$ROOT/Scripts/build-app.sh"

file "$EXECUTABLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "com.wonil.hosthop" ]]
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" == "HostHop" ]]
[[ ! -e "$APP/Contents/Helpers" ]]
[[ ! -e "$APP/Contents/Resources/HostHop.icns" ]]
[[ ! -e "$APP/Contents/Resources/default-config.plist" ]]

"$EXECUTABLE" --help

CODESIGN_DETAILS=$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)
if [[ "$CODESIGN_DETAILS" != *"runtime"* ]]; then
    print -u2 "Hardened Runtime is not enabled"
    exit 1
fi
ENTITLEMENTS=$(/usr/bin/codesign -d --entitlements :- "$APP" 2>&1 || true)
if [[ "$ENTITLEMENTS" == *"com.apple.security"* ]]; then
    print -u2 "Unexpected security exception entitlement"
    exit 1
fi

UNSAFE_RPATH=$(/usr/bin/otool -l "$EXECUTABLE" | /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; if ($2 != "/usr/lib/swift") print $2 }')
if [[ -n "$UNSAFE_RPATH" ]]; then
    print -u2 "Unexpected executable rpath: $UNSAFE_RPATH"
    exit 1
fi
UNSAFE_LIBRARY=$(/usr/bin/otool -L "$EXECUTABLE" | /usr/bin/tail -n +2 | /usr/bin/awk '{ print $1 }' | /usr/bin/grep -Ev '^(/System/Library/|/usr/lib/)' || true)
if [[ -n "$UNSAFE_LIBRARY" ]]; then
    print -u2 "Unexpected non-system dynamic library: $UNSAFE_LIBRARY"
    exit 1
fi

INJECTION_LIBRARY="$ROOT/build/libHostHopInjectionTest.dylib"
INJECTION_MARKER="$ROOT/build/dyld-injection-marker"
/usr/bin/clang -dynamiclib "$ROOT/Tests/Security/injection-marker.c" -o "$INJECTION_LIBRARY"
/bin/rm -f "$INJECTION_MARKER"
HOSTHOP_INJECTION_MARKER="$INJECTION_MARKER" DYLD_INSERT_LIBRARIES="$INJECTION_LIBRARY" "$EXECUTABLE" --help >/dev/null
if [[ -e "$INJECTION_MARKER" ]]; then
    print -u2 "Hardened Runtime failed: DYLD library injection succeeded"
    exit 1
fi

if /usr/bin/otool -L "$EXECUTABLE" | /usr/bin/grep -Eq 'CoreDisplay'; then
    print -u2 "Unexpected CoreDisplay dependency in HostHop"
    exit 1
fi
if /usr/bin/strings "$EXECUTABLE" | /usr/bin/grep -Eqi 'BetterDisplay|m1ddc|/usr/bin/ssh'; then
    print -u2 "Unexpected external monitor-control backend string in HostHop"
    exit 1
fi
if ! /usr/bin/strings "$EXECUTABLE" | /usr/bin/grep 'DCPAVServiceProxy' >/dev/null; then
    print -u2 "Missing built-in LG DDC transport"
    exit 1
fi
if /usr/bin/unzip -l "$ARCHIVE" | /usr/bin/grep -Eqi 'm1ddc|Contents/Helpers|BetterDisplay'; then
    print -u2 "Unexpected monitor-control artifact in HostHop archive"
    exit 1
fi

PERSONAL_SERIAL="457""600"
PERSONAL_DISPLAY_ID="9C9A""FF4E-3E8F-4FC1-A9F4-E2336B5849A4"
if /usr/bin/grep -R -I -n -E "$PERSONAL_SERIAL|$PERSONAL_DISPLAY_ID" \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=build --exclude-dir=dist "$ROOT"; then
    print -u2 "Repository contains a personal hardware identifier"
    exit 1
fi
if [[ -d "$ROOT/Tools/HostHopDDCRouteProbe" ]]; then
    print -u2 "Raw DDC route probe must not be published"
    exit 1
fi

SIZE_BYTES=$(/usr/bin/du -sk "$APP" | /usr/bin/awk '{ print $1 * 1024 }')
if (( SIZE_BYTES >= 2097152 )); then
    print -u2 "Bundle exceeds the 2 MiB target: $SIZE_BYTES bytes"
    exit 1
fi

print "Verification passed ($SIZE_BYTES bytes)."
