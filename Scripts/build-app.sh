#!/bin/zsh
# Builds Convertable.app from the SwiftPM package (no Xcode project needed) and ad-hoc signs it.
#   Scripts/build-app.sh            → build/Convertable.app
#   Scripts/build-app.sh --install  → also copies to /Applications and relaunches
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
CONF=${CONF:-release}
swift build -c "$CONF" --product ConvertableApp
swift build -c "$CONF" --product convertctl
BIN=".build/$CONF"
APP="build/Convertable.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ConvertableApp" "$APP/Contents/MacOS/Convertable"
cp "$BIN/convertctl" "$APP/Contents/MacOS/convertctl"
cp -R "$BIN/Convertable_ConvertableWeb.bundle" "$APP/Contents/Resources/"
sed "s/VERSION_PLACEHOLDER/$(git rev-list --count HEAD 2>/dev/null || echo 1)/" Scripts/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1))"
if [[ "$1" == "--install" ]]; then
  pkill -x Convertable 2>/dev/null || true
  rm -rf /Applications/Convertable.app
  cp -R "$APP" /Applications/
  open /Applications/Convertable.app
  echo "installed and launched /Applications/Convertable.app"
fi
