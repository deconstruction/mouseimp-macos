#!/bin/bash
# Packs the built application into a release disk image:
#
#   ./Scripts/make-dmg.sh            # builds (ad-hoc signed) and packs
#   ./Scripts/make-dmg.sh --no-build # packs dist/MouseImp.app as it is
#
# The version in the file name comes from the app's Info.plist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PACKAGE_DIR"

BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP="$PACKAGE_DIR/dist/MouseImp.app"

if [ "$BUILD" = "1" ]; then
  # Release images are ad-hoc signed: there is no Developer ID behind the project,
  # so a self signed certificate of the maintainer would only be misleading. Users
  # allow the app once (see README "Download").
  "$SCRIPT_DIR/build-app.sh" --adhoc
fi

if [ ! -d "$APP" ]; then
  echo "no app at $APP - run ./Scripts/build-app.sh first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
DMG="$PACKAGE_DIR/dist/MouseImp-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging $APP"
cp -R "$APP" "$STAGE/MouseImp.app"
# Drag-and-drop target for the usual "copy to Applications" gesture.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -quiet -volname "MouseImp $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"

echo "==> done"
ls -lh "$DMG"
shasum -a 256 "$DMG"
