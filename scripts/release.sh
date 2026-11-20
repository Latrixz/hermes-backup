#!/bin/bash
# Publishes a signed, notarized release to GitHub. Installed copies find it with "Check for Updates…".
#   scripts/release.sh 0.2.0 "What changed, in a line or two"
# Needs: a clean main branch, `gh` logged in, the Developer ID certificate and a notarytool profile.
set -euo pipefail
cd "$(dirname "$0")/.."

V="${1:?usage: scripts/release.sh <version> \"notes\"}"
NOTES="${2:?usage: scripts/release.sh <version> \"notes\"}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: QUANTUM APES PTE. LTD. (ZT64LKJB82)}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-quantumape}"

[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && { echo "v$V already exists." >&2; exit 1; }

swift test
if [[ "$(tr -d '[:space:]' < VERSION)" != "$V" ]]; then
  echo "$V" > VERSION
  git commit -q -m "Version $V" VERSION
fi

./build.sh --dmg   # signs and notarizes, because SIGN_IDENTITY and NOTARY_PROFILE are set
ASSET="build/Hermes-Backup-$V.dmg"
cp "build/Hermes Backup.dmg" "$ASSET"
spctl -a -vv -t open --context context:primary-signature "$ASSET" 2>&1 | grep -q "source=Notarized Developer ID" \
  || { echo "The DMG isn't notarized." >&2; exit 1; }

git tag -a "v$V" -m "Hermes Backup $V"
git push -q origin main "v$V"
gh release create "v$V" "$ASSET" --title "Hermes Backup $V" --notes "$NOTES"
echo "Released v$V"
