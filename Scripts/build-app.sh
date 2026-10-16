#!/bin/bash
# Builds MouseImp.app from the SwiftPM package.
#
#   ./Scripts/build-app.sh              -> dist/MouseImp.app (ad-hoc signed)
#   ./Scripts/build-app.sh --install    -> also copy it to /Applications
#   ./Scripts/build-app.sh --adhoc      -> always ad-hoc, ignore any certificate
#
# Only the Command Line Tools are required (no Xcode): `swift build` plus a hand
# assembled bundle. Use `--sign "Name"` to sign with a real certificate, which
# keeps the Accessibility permission stable across rebuilds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PACKAGE_DIR"

CONFIGURATION="release"
BUNDLE_NAME="MouseImp"
SIGN_IDENTITY=""
INSTALL=0
FORCE_ADHOC=0
# A release has to run everywhere: build both slices and lipo them together.
# `--archs host` builds only for this machine, which is faster while developing.
ARCHS="arm64 x86_64"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug" ;;
    --install) INSTALL=1 ;;
    --adhoc) FORCE_ADHOC=1 ;;
    --archs) shift; ARCHS="${1:-}"; [ "$ARCHS" = "host" ] && ARCHS="$(uname -m)" ;;
    --sign) shift; SIGN_IDENTITY="${1:-}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "==> building ($CONFIGURATION, arches: $ARCHS)"
SLICES=()
for arch in $ARCHS; do
  swift build -c "$CONFIGURATION" --arch "$arch"
  bin="$(swift build -c "$CONFIGURATION" --arch "$arch" --show-bin-path)/MouseImpMac"
  if [ ! -x "$bin" ]; then
    echo "binary not found: $bin" >&2
    exit 1
  fi
  SLICES+=("$bin")
done

BINARY="$PACKAGE_DIR/.build/MouseImpMac-universal"
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$BINARY"
else
  cp -f "${SLICES[0]}" "$BINARY"
fi

echo "==> binary: $(lipo -archs "$BINARY")"

APP="$PACKAGE_DIR/dist/$BUNDLE_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$BUNDLE_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MouseImp</string>
    <key>CFBundleIdentifier</key>
    <string>ru.deconstruction.mouseimp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MouseImp</string>
    <key>CFBundleDisplayName</key>
    <string>MouseImp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.02</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MouseImp for macOS - DirectScroll. Original MouseImp PRO (c) Nezhelsky Oskar, Goffmann Svetozar. Free use under the MouseImp license.</string>
</dict>
</plist>
PLIST

if [ "$FORCE_ADHOC" = "0" ] && [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "MouseImp Dev"; then
  SIGN_IDENTITY="MouseImp Dev"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing with '$SIGN_IDENTITY'"
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> signing ad-hoc (Accessibility permission may have to be granted again after rebuilds)"
  codesign --force --sign - "$APP"
fi

codesign --verify --deep --strict "$APP" && echo "signature ok"

if [ "$INSTALL" = "1" ]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/$BUNDLE_NAME.app"
  cp -R "$APP" "/Applications/$BUNDLE_NAME.app"
  echo "installed: /Applications/$BUNDLE_NAME.app"
fi

echo "==> done: $APP"
echo "Grant Accessibility: System Settings > Privacy & Security > Accessibility > add $BUNDLE_NAME"
