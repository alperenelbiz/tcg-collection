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
case "$1" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: scripts/install-mac.sh [--dry-run]" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "usage: scripts/install-mac.sh [--dry-run]" >&2; exit 1; }

bundle_id() { [[ -f "$1/Contents/Info.plist" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }

HERE=""
if [[ -e "$APP" || -L "$APP" ]]; then
  HERE="$(bundle_id "$APP")"
  if [[ "$HERE" != "$ID" ]]; then
    echo "The first version is still at /Applications/TCG Collection.app. Remove it first (phase 7)." >&2
    [[ "$DIR" != "/Applications" ]] && echo "(checked: $APP, bundle id '${HERE:-none}')" >&2
    exit 1
  fi
fi
OLDID=""
[[ -e "$OLD" || -L "$OLD" ]] && OLDID="$(bundle_id "$OLD")"

if (( DRY )); then
  echo "dry run: nothing is built, quit, copied or moved"
  echo "target: $APP"
  if [[ -z "$HERE" ]]; then echo "at the target: nothing; it would install"
  else echo "at the target: this app ($HERE); it would quit it if it runs and replace it"; fi
  if [[ "$OLDID" == "$ID" ]]; then echo "older app: $OLD ($OLDID); it would quit it and move it to the Trash"
  elif [[ -e "$OLD" || -L "$OLD" ]]; then echo "older app: $OLD (bundle id '${OLDID:-none}'); it would leave it alone"
  else echo "older app: none"; fi
  exit 0
fi

xcodegen generate >/dev/null
xcodebuild -project TCGCollection.xcodeproj -scheme TCGCollection -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build | grep -E "error|BUILD (SUCCEEDED|FAILED)"
# "is running" never launches the app; a plain quit could start it (or the Debug build) to quit it.
# Exit status of osascript is checked: a failed check is "cannot tell", never "not running".
running() {
  local out
  out="$(osascript -e "application id \"$ID\" is running" 2>/dev/null)" || {
    echo "Cannot tell if TCG Collection runs (osascript failed). Nothing was changed." >&2; exit 1; }
  [[ "$out" == "true" ]]
}
if running; then
  osascript -e "tell application id \"$ID\" to quit" 2>/dev/null || true
  for _ in {1..20}; do running || break; sleep 0.5; done
  if running; then
    echo "TCG Collection is still running after 10 s. Quit it and run this script again. Nothing was changed." >&2
    exit 1
  fi
fi
# Copy first, then swap with the old copy kept aside until the new one is in place.
rm -rf "$APP.new" "$APP.old"
if ! ditto build/Build/Products/Release/TCGCollection2.app "$APP.new"; then
  rm -rf "$APP.new"
  echo "The copy failed. Nothing was changed." >&2
  exit 1
fi
if [[ -e "$APP" || -L "$APP" ]]; then
  mv "$APP" "$APP.old" || { rm -rf "$APP.new"; echo "Could not move the installed app aside. Nothing was changed." >&2; exit 1; }
fi
if ! mv "$APP.new" "$APP"; then
  [[ -e "$APP.old" ]] && mv "$APP.old" "$APP"
  rm -rf "$APP.new"
  echo "Could not put the new app in place; the old app was put back." >&2
  exit 1
fi
rm -rf "$APP.old"
echo "installed $APP"
if [[ "$OLDID" == "$ID" ]]; then
  # Same bundle id as the new app: the quit above covered a running copy.
  osascript -e "tell application \"Finder\" to delete POSIX file \"$OLD\"" >/dev/null
  echo "moved the older $OLD to the Trash"
fi
