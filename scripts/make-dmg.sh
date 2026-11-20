#!/bin/bash
# Packs "build/Hermes Backup.app" into "build/Hermes Backup.dmg": the app beside an Applications
# shortcut, on a background with an arrow, so installing is one drag.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Hermes Backup.app"
DMG="build/Hermes Backup.dmg"
VOL="Hermes Backup"
STAGE="build/dmg-stage"
RW="build/dmg-rw.dmg"

[[ -d "$APP" ]] || { echo "Build the app first: $APP is missing" >&2; exit 1; }
# A volume with the same name already mounted would take the Finder layout instead.
[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -quiet || true

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" -quiet
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*$')
SetFile -a C "$MNT" 2>/dev/null || true   # show .VolumeIcon.icns as the disk's icon

# Window size, icon positions and background are stored in the volume's .DS_Store by Finder.
osascript <<OSA || echo "Note: couldn't style the window (Finder automation denied?). The DMG still works."
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 488}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Hermes Backup.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    -- Hidden files show when Finder is set to show them: park them out of view.
    repeat with n in {".background", ".fseventsd", ".VolumeIcon.icns", ".DS_Store", ".Trashes"}
      try
        set position of item (n as text) of container window to {900, 900}
      end try
    end repeat
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$STAGE" "$RW"
echo "Built $DMG"
