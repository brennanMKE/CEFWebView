#!/bin/zsh
# idle-probe.sh — guest script for Scripts/run-tests-vm.sh --guest-script.
#
# Builds the demo app in Release (ad hoc), launches it on a static page, lets it settle, then
# measures each process's CPU over a quiet minute. Also records whether Chromium's notification
# service started (the "(Alerts)" helper) and whether macOS registered the app with Notification
# Center, which is what makes the "Notifications may include alerts…" banner appear.
#
# Run from the source directory with RESULTS set; writes $RESULTS/idle-probe.txt.

set -euo pipefail
RESULTS="${RESULTS:?}"
DD="$HOME/dd"
OUT="$RESULTS/idle-probe.txt"
SETTLE_SECS=120
SAMPLE_SECS=60

xcodebuild -project WebView/WebView.xcodeproj -scheme WebView -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  build > "$RESULTS/release-build.log" 2>&1 || { tail -30 "$RESULTS/release-build.log"; exit 1; }
APP="$DD/Build/Products/Release/WebView.app"

page='data:text/html,<title>Idle</title><h1>Idle page</h1><p>Static text, no script.</p>'
open -n "$APP" --args -StartURL "$page"
sleep "$SETTLE_SECS"

# CPU seconds used by every WebView process, summed per command name.
cpu_seconds() {
  ps -axo time=,comm= | awk '/WebView/ {
    n = split($1, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i];
    name = $0; sub(/^ *[0-9:.]+ +/, "", name); sub(/.*\//, "", name); cpu[name] += s
  } END { for (k in cpu) printf "%s\t%.2f\n", k, cpu[k] }' | sort
}

cpu_seconds > "$RESULTS/cpu-before.tsv"
sleep "$SAMPLE_SECS"
cpu_seconds > "$RESULTS/cpu-after.tsv"

{
  print "== Average CPU over ${SAMPLE_SECS}s idle (after ${SETTLE_SECS}s settle)"
  join -t $'\t' "$RESULTS/cpu-before.tsv" "$RESULTS/cpu-after.tsv" \
    | awk -F'\t' -v secs="$SAMPLE_SECS" '{ pct = ($3 - $2) / secs * 100; total += pct;
        printf "%6.2f%%  %s\n", pct, $1 } END { printf "%6.2f%%  TOTAL\n", total }'
  print
  print "== WebView processes"
  ps -axo pid=,comm= | grep WebView | sed 's#/.*/##'
  print
  print "== Alerts helper running?"
  pgrep -fl 'WebView Helper (Alerts)' || print "no"
  print
  print "== Notification Center registrations for co.sstools"
  db="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
  if [[ -f "$db" ]]; then
    sqlite3 "$db" "select identifier from app where identifier like '%sstools%';" 2>&1 || true
  else
    print "(no db at $db)"
  fi
  defaults read com.apple.ncprefs apps 2>/dev/null | grep -i 'sstools' || print "(none in ncprefs)"
  print
  print "== usernoted log mentioning the app"
  /usr/bin/log show --last 5m --style compact --predicate \
    'process == "usernoted" AND eventMessage CONTAINS[c] "sstools"' 2>/dev/null | tail -20
} > "$OUT"

# Where the app process spends its idle time, and how often it wakes.
pid="$(pgrep -x WebView | head -1)"
sample "$pid" 10 -file "$RESULTS/sample-WebView.txt" >/dev/null 2>&1 || true
top -l 3 -s 5 -stats pid,command,cpu,idlew,threads | grep -E 'PID|WebView' > "$RESULTS/top.txt" || true

cat "$OUT"
osascript -e 'quit app "WebView"' 2>/dev/null || pkill -x WebView || true
