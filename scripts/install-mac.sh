#!/bin/zsh
# Builds the Mac app (Release) and puts it in /Applications as "TCG Collection.app".
# Run it again after a code change. The catalog and prices stay: they live in Application Support
# and Caches under TCGCollection2, not in the app bundle.
# It quits and replaces only the app with bundle id com.alperenelbiz.tcgcollection2. An app with another
# bundle id at the target (the first version) is never touched: the script stops with exit 1 (phase 7, A69).
# After the install it quits and moves an older "TCG Collection 2.app" of this app to the Trash.
# --dry-run prints the decisions and runs nothing. APPLICATIONS_DIR (default /Applications) is a seam for checks.
set -e -o pipefail
cd "${0:A:h:h}"
ID="com.alperenelbiz.tcgcollection2"
DIR="${APPLICATIONS_DIR:-/Applications}"
APP="$DIR/TCG Collection.app"
OLD="$DIR/TCG Collection 2.app"
DRY=0
[[ "$1" == "--dry-run" ]] && DRY=1

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }

HERE=""
if [[ -e "$APP" ]]; then
  HERE="$(bundle_id "$APP")"
  if [[ "$HERE" != "$ID" ]]; then
    echo "The first version is still at /Applications/TCG Collection.app. Remove it first (phase 7)." >&2
    [[ "$DIR" != "/Applications" ]] && echo "(checked: $APP, bundle id '${HERE:-none}')" >&2
    exit 1
  fi
fi
OLDID=""
[[ -e "$OLD" ]] && OLDID="$(bundle_id "$OLD")"

if (( DRY )); then
  echo "dry run: nothing is built, quit, copied or moved"
  echo "target: $APP"
  if [[ -z "$HERE" ]]; then echo "at the target: nothing; it would install"
  else echo "at the target: this app ($HERE); it would quit it if it runs and replace it"; fi
  if [[ "$OLDID" == "$ID" ]]; then echo "older app: $OLD ($OLDID); it would quit it and move it to the Trash"
  elif [[ -e "$OLD" ]]; then echo "older app: $OLD (bundle id '${OLDID:-none}'); it would leave it alone"
  else echo "older app: none"; fi
  exit 0
fi

xcodegen generate >/dev/null
xcodebuild -project TCGCollection.xcodeproj -scheme TCGCollection -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build | grep -E "error|BUILD (SUCCEEDED|FAILED)"
# "is running" never launches the app; a plain quit could start it (or the Debug build) to quit it.
osascript -e "if application id \"$ID\" is running then tell application id \"$ID\" to quit" 2>/dev/null || true
sleep 1
rm -rf "$APP"
ditto build/Build/Products/Release/TCGCollection2.app "$APP"
echo "installed $APP"
if [[ "$OLDID" == "$ID" ]]; then
  # Same bundle id as the new app: the quit above covered a running copy.
  osascript -e "tell application \"Finder\" to delete POSIX file \"$OLD\"" >/dev/null
  echo "moved the older $OLD to the Trash"
fi
