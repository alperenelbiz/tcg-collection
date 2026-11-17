#!/bin/zsh
# Runs the iPhone UI tests (scheme TCGCollectionPhoneUI) in the iOS Simulator and exports their screenshots.
# Every test runs the Debug app on a fresh temporary store and the fixture network: no network, no real store.
# They take no pointer and need no "Enable UI Automation" approval on the Mac.
# Usage: scripts/ui-test-phone.sh [output dir]   (default: build/ui-phone)
# Output: <dir>/ui.xcresult, <dir>/xcodebuild.log, <dir>/shots/*.png (+ manifest.json).
set -e -o pipefail
cd "${0:A:h:h}"
OUT="${1:-build/ui-phone}"

rm -rf "$OUT/ui.xcresult" "$OUT/shots"
mkdir -p "$OUT"
xcodegen generate >/dev/null

STATUS=0
# Debug, always: the Debug app has its own bundle id, and only Debug has the fixture network.
xcodebuild test -project TCGCollection.xcodeproj -scheme TCGCollectionPhoneUI -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build -resultBundlePath "$OUT/ui.xcresult" >"$OUT/xcodebuild.log" 2>&1 || STATUS=$?
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
