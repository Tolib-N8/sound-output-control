#!/bin/zsh
# Builds a universal Release of Soundflow and packages it into dist/Soundflow-<version>.dmg.
# Requires: xcodegen, python3 with dmgbuild (`python3 -m pip install --user dmgbuild`).
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
WORK=$(mktemp -d "${TMPDIR:-/tmp}/soundflow-release.XXXXXX")  # outside iCloud-synced folders: codesign rejects their xattrs
trap 'rm -rf "$WORK"' EXIT

echo "→ Building Soundflow $VERSION (universal Release)"
xcodegen generate --quiet
xcodebuild -project Soundflow.xcodeproj -scheme Soundflow -configuration Release \
  -derivedDataPath "$WORK/build" ONLY_ACTIVE_ARCH=NO build -quiet
APP="$WORK/build/Build/Products/Release/Soundflow.app"
codesign --verify --deep --strict "$APP"

echo "→ Rendering artwork"
swift scripts/render_art.swift "$WORK/art" >/dev/null
tiffutil -cathidpicheck "$WORK/art/dmg-background.png" "$WORK/art/dmg-background@2x.png" -out "$WORK/art/background.tiff" 2>/dev/null

echo "→ Packaging DMG"
mkdir -p dist
DMG="dist/Soundflow-$VERSION.dmg"
rm -f "$DMG"
python3 -m dmgbuild -s scripts/dmg_settings.py \
  -D app="$APP" -D background="$WORK/art/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Soundflow $VERSION" "$DMG"
hdiutil verify "$DMG" >/dev/null
# Gatekeeper rejects bundles with Finder metadata, so check the copy users will actually get.
MNT=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | tail -1 | cut -f3-)
codesign --verify --deep --strict "$MNT/Soundflow.app"
hdiutil detach "$MNT" -quiet
shasum -a 256 "$DMG"
echo "✓ $DMG"
