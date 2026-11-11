#!/bin/zsh
# Runs the Mac UI tests (scheme TCGCollectionUI) and exports their screenshots.
# The tests take the pointer and bring the app window to the front while they run.
# Every test runs the Debug app on a fresh temporary store and the fixture network: no network, no real store.
# Usage: scripts/ui-test.sh [output dir]   (default: build/ui)
# Output: <dir>/ui.xcresult, <dir>/xcodebuild.log, <dir>/shots/*.png (+ manifest.json; a failed test also
# keeps a screen recording, .mp4). macOS may ask the owner to "Enable UI Automation" (Touch ID or password):
# the runner waits 60 s for it, then fails with "Timed out while enabling automation mode."
set -e -o pipefail
cd "${0:A:h:h}"
OUT="${1:-build/ui}"

rm -rf "$OUT/ui.xcresult" "$OUT/shots"
mkdir -p "$OUT"
xcodegen generate >/dev/null

STATUS=0
xcodebuild test -project TCGCollection.xcodeproj -scheme TCGCollectionUI -destination 'platform=macOS' \
  -derivedDataPath build -resultBundlePath "$OUT/ui.xcresult" >"$OUT/xcodebuild.log" 2>&1 || STATUS=$?
# XCUITest ends a running instance of the app it tests: that is the Debug app, never the installed one.
echo "tested app: $(defaults read "$PWD/build/Build/Products/Debug/TCGCollection2.app/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "not built")"
grep -E "error:|Test Case .* failed" "$OUT/xcodebuild.log" | sort -u || true
grep -E "Executed [0-9]+ tests?, with" "$OUT/xcodebuild.log" | tail -1 || true
grep -E "TEST (SUCCEEDED|FAILED)" "$OUT/xcodebuild.log" || true

if [[ -d "$OUT/ui.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$OUT/ui.xcresult" --output-path "$OUT/shots" >/dev/null
  # One line per picture: test, attachment name, file.
  jq -r '.[] | .testIdentifier as $test | .attachments[]
         | select(.exportedFileName | endswith(".png"))
         | "\($test)  \(.suggestedHumanReadableName)  '"$OUT"'/shots/\(.exportedFileName)"' "$OUT/shots/manifest.json"
fi
exit $STATUS
