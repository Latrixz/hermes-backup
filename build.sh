#!/bin/bash
# Builds "Hermes Backup.app" into ./build.
#   ./build.sh                     local build, ad-hoc signed (runs on this Mac only)
#   ./build.sh --install           also copies it to /Applications
#   ./build.sh --local --install   quicker: this Mac's chip only (never for sharing)
#   ./build.sh --dmg               also makes "build/Hermes Backup.dmg"
# Signed and notarized, to send to someone else:
#   SIGN_IDENTITY="Developer ID Application: QUANTUM APES PTE. LTD. (ZT64LKJB82)" NOTARY_PROFILE=quantumape ./build.sh --dmg
set -euo pipefail
cd "$(dirname "$0")"

LOCAL=0; MAKE_DMG=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --dmg) MAKE_DMG=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
[[ -n "${NOTARY_PROFILE:-}" ]] && MAKE_DMG=1
if [[ $LOCAL == 1 && ( $MAKE_DMG == 1 || -n "${SIGN_IDENTITY:-}" ) ]]; then
  echo "--local is for this Mac only; anything shared must be universal." >&2; exit 1
fi

if [[ $LOCAL == 1 ]]; then
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/HermesBackup"
else
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/HermesBackup"
fi

APP="build/Hermes Backup.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HermesBackup"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuIcon.png "$APP/Contents/Resources/MenuIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hermes Backup</string>
  <key>CFBundleDisplayName</key><string>Hermes Backup</string>
  <key>CFBundleIdentifier</key><string>com.quantumape.hermesbackup</string>
  <key>CFBundleExecutable</key><string>HermesBackup</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Hermes Backup saves copies to your external disk.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Hermes Backup saves copies to your Documents folder.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Hermes Backup saves copies to network drives you choose.</string>
  <key>NSFileProviderDomainUsageDescription</key><string>Hermes Backup saves copies to your cloud folders.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi
echo "Built $APP $VERSION (signed: $IDENTITY)"

if [[ $MAKE_DMG == 1 ]]; then
  scripts/make-dmg.sh
  DMG="build/Hermes Backup.dmg"
  [[ "$IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$IDENTITY" == "-" ]] && { echo "Notarizing needs SIGN_IDENTITY." >&2; exit 1; }
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Notarized: $DMG is ready to send"
  fi
fi

if [[ $INSTALL == 1 ]]; then
  # Quit a running copy first, or it keeps running the old build until it's restarted.
  WAS_RUNNING=0
  if pgrep -qf "Hermes Backup.app/Contents/MacOS"; then
    WAS_RUNNING=1
    osascript -e 'quit app id "com.quantumape.hermesbackup"' || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -qf "Hermes Backup.app/Contents/MacOS" || break; sleep 0.5; done
  fi
  rm -rf "/Applications/Hermes Backup.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications"
  if [[ $WAS_RUNNING == 1 ]]; then
    # Launch Services can refuse (-600) for a moment right after the copy; try a few times.
    for _ in 1 2 3 4 5; do open -g "/Applications/Hermes Backup.app" 2>/dev/null && break; sleep 1; done
    if pgrep -qf "Hermes Backup.app/Contents/MacOS" || { sleep 1; pgrep -qf "Hermes Backup.app/Contents/MacOS"; }; then
      echo "Restarted Hermes Backup"
    else
      echo "Couldn't reopen Hermes Backup — open it from Applications." >&2
    fi
  fi
fi
