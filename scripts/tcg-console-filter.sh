#!/bin/zsh
# Filters the console of the app launched by `scripts/install-iphone.sh --launch-console` (A68).
#
#   <console stream> | scripts/tcg-console-filter.sh <log file>
#
# Reads standard input line by line. Every line goes to <log file> (the whole console, byte for byte). A line goes to
# standard output only when it starts with one of these (the app's step lines, and devicectl's own lines that say the
# app was launched, is awaited or ended): `tcg: `, `Launched application`, `Waiting for the application`,
# `The app terminated`, `App terminated`. Each line is written at once, so a live console shows its lines as they come.
if [[ $# -ne 1 ]]; then
  print -u2 "Usage: tcg-console-filter.sh <log file>"
  exit 1
fi
log="$1"
: > "$log" || exit 1
exec {fd}>>"$log"

line=""
while true; do
  IFS= read -r line
  rc=$?
  # rc 0: a whole line. rc 1 with text: a last line with no newline. rc 1 with no text: the end.
  if (( rc == 0 )); then
    nl=$'\n'
  elif [[ -n "$line" ]]; then
    nl=""
  else
    break
  fi
  print -rn -- "$line$nl" >&$fd
  if [[ "$line" == ('tcg: '|'Launched application'|'Waiting for the application'|'The app terminated'|'App terminated')* ]]; then
    print -rn -- "$line$nl"
  fi
  (( rc == 0 )) || break
done
