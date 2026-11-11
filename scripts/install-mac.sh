#!/bin/zsh
# Builds the Mac app (Release) and puts it in /Applications as "TCG Collection 2.app".
# Run it again after a code change. The catalog and prices stay: they live in Application Support
# and Caches under TCGCollection2, not in the app bundle.
# It quits and replaces only the app with bundle id com.alperenelbiz.tcgcollection2.
set -e -o pipefail
cd "${0:A:h:h}"
APP="/Applications/TCG Collection 2.app"
xcodegen generate >/dev/null
xcodebuild -project TCGCollection.xcodeproj -scheme TCGCollection -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build | grep -E "error|BUILD (SUCCEEDED|FAILED)"
# "is running" never launches the app; a plain quit could start it (or the Debug build) to quit it.
osascript -e 'if application id "com.alperenelbiz.tcgcollection2" is running then tell application id "com.alperenelbiz.tcgcollection2" to quit' \
  2>/dev/null || true
sleep 1
rm -rf "$APP"
ditto build/Build/Products/Release/TCGCollection2.app "$APP"
echo "installed $APP"
