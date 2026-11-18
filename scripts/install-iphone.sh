#!/bin/zsh
# Builds the iPhone app (Release) and installs it on the one paired physical iPhone (A60).
#
#   scripts/install-iphone.sh                   build, then install
#   scripts/install-iphone.sh --dry-run         print the chosen device and the commands, run nothing, exit 0
#   scripts/install-iphone.sh --launch-console  build, install, then launch the app with its console attached
#                                               (only the app's `tcg: ` step lines and devicectl's launched / awaited /
#                                               terminated lines show; the whole console goes to
#                                               build/iphone/console-<yyyy-MM-dd-HHmmss>.log; Ctrl+C stops it)
#
# The device: the one line of `xcrun devicectl list devices` whose Reality is "physical", whose State is
# "available (paired)" and whose model is an iPhone (`(iPhoneNN,N)`). No such line, or more than one, is an error (exit
# 1): the script never picks a simulator or guesses between two devices. DEVICES_LIST=<file> reads that list from a file
# instead (the tests of this script: no device, two devices, a simulator only).
#
# A free Apple account signs the app for 7 days: run this script again after that. Signing: Config/Local.xcconfig (team)
# and automatic signing. `-allowProvisioningUpdates` lets xcodebuild make or renew the iOS development profile of the
# bundle id through the Apple account signed in to Xcode (without it the first device build fails: "No profiles for
# 'com.alperenelbiz.tcgcollection2' were found"); it registers the iPhone with that account the first time.
# The catalog, prices and pictures stay on the iPhone across a reinstall; the collection lives in the folder picked there.
set -e -o pipefail
cd "${0:A:h:h}"

BUNDLE_ID="com.alperenelbiz.tcgcollection2"
APP="build/iphone/Build/Products/Release-iphoneos/TCGCollection2.app"

dry_run=0
launch_console=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --launch-console) launch_console=1 ;;
    *) print -u2 "Unknown option: $arg (use --dry-run or --launch-console)"; exit 1 ;;
  esac
done

if [[ -n "${DEVICES_LIST:-}" ]]; then
  if [[ ! -r "$DEVICES_LIST" ]]; then
    print -u2 "DEVICES_LIST names no readable file: $DEVICES_LIST"
    exit 1
  fi
  list="$(<"$DEVICES_LIST")"
else
  if ! list="$(xcrun devicectl list devices 2>&1)"; then
    print -u2 "xcrun devicectl list devices failed:"
    print -u2 -- "$list"
    exit 1
  fi
fi

# The paired physical iPhones: Reality (the last column) "physical", State "available (paired)", an iPhone model id.
matches=("${(@f)$(print -r -- "$list" | LC_ALL=C awk '
  $NF == "physical" && /available \(paired\)/ && /\(iPhone[0-9]+,[0-9]+\)/ { print }')}")
matches=(${matches:#})   # drop the empty element of no match

udid_of() {
  print -r -- "$1" | LC_ALL=C grep -oE '[0-9A-Fa-f][0-9A-Fa-f-]{15,} \(UDID\)' | head -n 1 | cut -d' ' -f1
}
model_of() {
  print -r -- "$1" | LC_ALL=C grep -oE 'iPhone[^()]*\(iPhone[0-9]+,[0-9]+\)' | tail -n 1
}

if (( ${#matches} == 0 )); then
  print -u2 "No paired iPhone: no line of 'xcrun devicectl list devices' is physical, available (paired) and an iPhone."
  print -u2 "Connect the iPhone by cable (or turn on its Wi-Fi pairing), unlock it, and run this again."
  exit 1
fi
if (( ${#matches} > 1 )); then
  print -u2 "More than one paired iPhone (${#matches}); this script installs on exactly one:"
  for line in $matches; do print -u2 "  $(model_of "$line") $(udid_of "$line")"; done
  print -u2 "Disconnect the others, and run this again."
  exit 1
fi

udid="$(udid_of "${matches[1]}")"
model="$(model_of "${matches[1]}")"
if [[ -z "$udid" || ! "$udid" =~ '^[0-9A-Fa-f-]+$' ]]; then
  print -u2 "The paired iPhone's line has no UDID that can be read:"
  print -u2 -- "${matches[1]}"
  exit 1
fi

build_cmd=(xcodebuild build -project TCGCollection.xcodeproj -scheme TCGCollection -configuration Release
  -destination "id=$udid" -derivedDataPath build/iphone -allowProvisioningUpdates)
install_cmd=(xcrun devicectl device install app --device "$udid" "$APP")
launch_cmd=(xcrun devicectl device process launch --console --device "$udid" "$BUNDLE_ID")
console_log="build/iphone/console-$(date +%Y-%m-%d-%H%M%S).log"
filter_cmd=(scripts/tcg-console-filter.sh "$console_log")

if (( dry_run )); then
  print "device: $model $udid"
  print "build: ${(q-)build_cmd[@]}"
  print "install: ${(q-)install_cmd[@]}"
  (( launch_console )) && print "launch: ${(q-)launch_cmd[@]} 2>&1 | ${(q-)filter_cmd[@]}"
  exit 0
fi

print "device: $model $udid"
xcodegen generate >/dev/null
"${build_cmd[@]}" | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
"${install_cmd[@]}"
print "installed $BUNDLE_ID on $udid"
if (( launch_console )); then
  mkdir -p build/iphone
  print "console log: $console_log"
  # pipefail (`set -e -o pipefail` at the top): a failed devicectl fails the pipeline, not only a failed filter. `set +e`
  # around it so a failure is said with the log's end before the script exits with the same status.
  set +e
  "${launch_cmd[@]}" 2>&1 | "${filter_cmd[@]}"
  launch_status=$?
  set -e
  if (( launch_status != 0 )); then
    print -u2 "devicectl failed (exit $launch_status): see $console_log"
    tail -n 10 "$console_log" >&2
    exit $launch_status
  fi
fi
