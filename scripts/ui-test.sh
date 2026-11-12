#!/bin/zsh
# Runs the Mac UI tests (scheme TCGCollectionUI) and exports their screenshots.
# The tests take the pointer and bring the app window to the front while they run.
# Every test runs the Debug app on a fresh temporary store and the fixture network: no network, no real store.
# The two exceptions, RealCatalogTests and RealCollectionTests, run only with the variables below, offline.
# Usage: scripts/ui-test.sh [output dir]   (default: build/ui)
#        TCG_REAL_STORE=<store root> [TCG_REAL_CSV_DIR=<csv dir>] scripts/ui-test.sh [output dir]
#   With TCG_REAL_STORE, RealCatalogTests also runs, offline, on that root (it needs <root>/support/catalog.store).
#   Give it a copy of a real store; the test leaves the root. Without it, both real tests are skipped.
#   With TCG_REAL_CSV_DIR too, RealCollectionTests imports <csv dir>/riftbound.csv and yu-gi-oh.csv into that root
#   (<root>/user must hold no riftbound.json or yu-gi-oh.json: remove <root>/user of the copy first). Give it copies.
# Output: <dir>/ui.xcresult, <dir>/xcodebuild.log, <dir>/shots/*.png (+ manifest.json; a failed test also
# keeps a screen recording, .mp4). macOS may ask the owner to "Enable UI Automation" (Touch ID or password):
# the runner waits 60 s for it, then fails with "Timed out while enabling automation mode."
set -e -o pipefail
if [[ -n "${TCG_REAL_STORE:-}" ]]; then
  # xcodebuild passes TEST_RUNNER_<name> to the test runner as <name>. Absolute, from the caller's folder.
  export TEST_RUNNER_TCG_REAL_STORE="${TCG_REAL_STORE:A}"
  echo "real store root: $TEST_RUNNER_TCG_REAL_STORE"
fi
if [[ -n "${TCG_REAL_CSV_DIR:-}" ]]; then
  export TEST_RUNNER_TCG_REAL_CSV_DIR="${TCG_REAL_CSV_DIR:A}"
  echo "real CSV folder: $TEST_RUNNER_TCG_REAL_CSV_DIR"
fi
cd "${0:A:h:h}"
OUT="${1:-build/ui}"

rm -rf "$OUT/ui.xcresult" "$OUT/shots"
mkdir -p "$OUT"
xcodegen generate >/dev/null

STATUS=0
# Debug, always: the Debug app has its own bundle id, and only Debug has the fixture network.
xcodebuild test -project TCGCollection.xcodeproj -scheme TCGCollectionUI -configuration Debug -destination 'platform=macOS' \
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
