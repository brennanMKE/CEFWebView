#!/bin/zsh
# run-tests-vm.sh — run the demo app's integration and UI tests inside a disposable Tart VM.
#
#   Scripts/run-tests-vm.sh                  # the working tree, every test in the WebView scheme
#   Scripts/run-tests-vm.sh --ref HEAD       # a commit instead of the working tree
#   Scripts/run-tests-vm.sh -- -only-testing:'WebViewTests/CEFWebViewAPITests/findsTextInThePage()'
#
# These tests open windows, take focus and send mouse events, so they never run on the host.
# See docs/TESTING_IN_TART.md. Each run clones the host's shared golden image, boots it headless,
# builds and tests inside the guest, copies the results to build/vm-tests/<run-id>/, and deletes the
# clone. Arguments after `--` go to `xcodebuild test`.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REF=""
XCODEBUILD_ARGS=()
while (( $# )); do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --) shift; XCODEBUILD_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) print -r -- "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# One shared golden for every project on this host, resolved, never a literal name. `require` fails
# in a second if its Xcode is wrong. See Homelab protocols/tart-golden/PROTOCOL.md.
command -v tart-golden >/dev/null 2>&1 || {
  print -r -- "tart-golden not found on PATH -- see Homelab protocols/tart-golden/PROTOCOL.md" >&2
  exit 1
}
GOLDEN="$(tart-golden require --xcode 27.0)"
GUEST_SRC="/Users/admin/src"
GUEST_RESULTS="/Users/admin/results"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="cefwebview-uitest-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/cefwebview-uitest-export.XXXXXX")"
RESULTS_DIR="$REPO/build/vm-tests/$RUN_ID"
BOOT_TIMEOUT_SECS=120
LEASE_ID=""

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  # Give the Tart slot back first so a waiting session starts sooner. See tart-lease/PROTOCOL.md.
  if [[ -n "$LEASE_ID" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
  fi
  if [[ -n "${MEMORY_REQUEST_ID:-}" ]]; then
    /usr/bin/python3 - "${MEMORY_COORD_DIR:-}" "$MEMORY_REQUEST_ID" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
dir, rid = sys.argv[1:3]
if not dir:
    raise SystemExit(0)
os.makedirs(os.path.join(dir, "release"), exist_ok=True)
doc = {"id": rid, "released": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(os.path.join(dir, "release", rid + ".json"), "w") as f:
    json.dump(doc, f, indent=2)
PY
  fi
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
tart list | grep -q "$GOLDEN" || fail "Golden image '$GOLDEN' not found"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / -- need at least 20 GiB"

# --- Memory (generic memory-signal protocol) -------------------------------
# The guest needs its RAM plus build headroom. When the host is short, ask this machine's observer to
# free memory and wait. What it frees is configured on the machine, never here.

GUEST_MEM_MB=$(tart get "$GOLDEN" --format json 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("Memory", 12288))' 2>/dev/null || print 12288)

memory_available_bytes() {
  local page free inactive purgeable
  page=$(sysctl -n vm.pagesize)
  free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  purgeable=$(vm_stat | awk '/Pages purgeable/ {gsub("\\.","",$3); print $3}')
  print -r -- $(( (free + inactive + purgeable) * page ))
}

memory_observer_live() {
  local dir hb now mtime
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  hb="$dir/heartbeat"
  [[ -f "$hb" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$hb" 2>/dev/null) || return 1
  (( now - mtime <= 15 ))
}

# 0 ready, 3 failed, 4 timeout or no observer. Sets MEMORY_REQUEST_ID for the release in cleanup.
memory_request_and_wait() {
  local need_bytes=$1 reason=$2 timeout=${3:-120}
  local dir id req deadline
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  id="cefwebview-run-tests-vm-$$-$(date +%s)"
  req="$dir/requests/$id.json"
  MEMORY_REQUEST_ID="$id"
  MEMORY_COORD_DIR="$dir"

  memory_observer_live || { MEMORY_REQUEST_ID=""; return 4; }

  mkdir -p "$dir/requests" "$dir/ready" "$dir/failed" "$dir/release"
  /usr/bin/python3 - "$req" "$id" "$need_bytes" "$reason" "$$" <<'PY'
import json, sys, datetime
path, rid, need, reason, pid = sys.argv[1:6]
doc = {
    "id": rid,
    "resource": "memory",
    "bytes": int(need),
    "requester": "cefwebview-run-tests-vm",
    "reason": reason,
    "pid": int(pid),
    "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

  deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    [[ -f "$dir/ready/$id.json" ]] && return 0
    if [[ -f "$dir/failed/$id.json" ]]; then
      /usr/bin/python3 -c 'import json,sys; print("memory-signal failed:", json.load(open(sys.argv[1])).get("reason","?"))' "$dir/failed/$id.json" >&2
      return 3
    fi
    sleep 2
  done
  return 4
}

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
avail_bytes=$(memory_available_bytes)
if (( avail_bytes < need_bytes )); then
  log "Host memory short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB) -- requesting via the memory-signal protocol"
  set +e
  memory_request_and_wait "$need_bytes" "Tart VM test run needs guest RAM plus build headroom" 120
  mem_rc=$?
  set -e
  (( mem_rc == 0 )) || fail "Memory request not fulfilled (rc=$mem_rc). Free memory, or start a memory-signal observer"
fi

# A SIGKILL skips the trap, so sweep clones earlier runs left behind. Only names in this script's own
# run-id shape are touched, which can never match a golden image.
stale=$(tart list | awk '$2 ~ /^cefwebview-uitest-[0-9]{8}-[0-9]{6}-[0-9]+$/ { print $2 }' | grep -v -- "$CLONE" || true)
for old in ${=stale}; do
  [[ "$old" == "$GOLDEN" ]] && { print -r -- "!! refusing to sweep the golden image" >&2; continue; }
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# --- Export a snapshot -----------------------------------------------------
# One tar file: Tart's shared folders do not pass symlinks through, and the CEF framework is full of
# them. By default the snapshot is the working tree (tracked and new files, minus .gitignore), taken
# through a throwaway index so the real one is untouched. --ref exports a commit instead.

if [[ -n "$REF" ]]; then
  TREE="$REF"
  log "Exporting $REF"
else
  TMP_INDEX="$EXPORT/index"
  cp "$REPO/.git/index" "$TMP_INDEX"
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" add -A
  TREE="$(GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" write-tree)"
  rm -f "$TMP_INDEX"
  log "Exporting the working tree ($TREE)"
fi
git -C "$REPO" archive --format=tar -o "$EXPORT/src.tar" "$TREE"

# The CEF XCFramework is gitignored. Ship the local copy so the guest does not download 145 MB; without
# it, Package.swift falls back to the GitHub release.
if [[ -d "$REPO/Frameworks/ChromiumEmbeddedFramework.xcframework" ]]; then
  log "Adding the local CEF framework"
  tar -C "$REPO" -rf "$EXPORT/src.tar" Frameworks
fi

# --- Wait for a Tart slot --------------------------------------------------

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label cefwebview --pid $$)
else
  log "WARNING: tart-lease not on PATH -- running without admission control"
fi

# --- Clone and boot --------------------------------------------------------

log "Cloning $GOLDEN -> $CLONE"
tart clone "$GOLDEN" "$CLONE"

log "Booting $CLONE (headless, no audio, export mounted read-only)"
tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || fail "Guest did not become reachable within ${BOOT_TIMEOUT_SECS}s"
  sleep 5
done
log "Guest reachable"

# --- In the guest ----------------------------------------------------------

tart exec "$CLONE" /bin/zsh -lc "rm -rf $GUEST_SRC $GUEST_RESULTS && mkdir -p $GUEST_SRC $GUEST_RESULTS \
  && tar -xf '/Volumes/My Shared Files/run/src.tar' -C $GUEST_SRC"

# The guest has no signing identity: sign ad hoc, which also turns off the hardened runtime (library
# validation rejects ad-hoc code) and makes CEFWebView use the mock keychain, so nothing prompts.
SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=-" DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
EXTRA="${(j: :)${(q)XCODEBUILD_ARGS[@]}}"

log "Building and testing in the guest"
set +e
# pipefail inside the guest shell: without it the status is tee's, always 0.
tart exec "$CLONE" /bin/zsh -lc \
  "set -o pipefail; cd $GUEST_SRC && xcodebuild -project WebView/WebView.xcodeproj -scheme WebView \
     -destination 'platform=macOS' -resultBundlePath $GUEST_RESULTS/Tests.xcresult ${SIGNING[*]} \
     test $EXTRA 2>&1 | tee $GUEST_RESULTS/xcodebuild.log"
test_rc=$?
set -e

# What xcodebuild's output leaves out: the app's own log lines (CEFWrapper's NSLog), Chromium's log
# file, and crash reports for the app and its helpers. /usr/bin/log, not zsh's `log` builtin.
tart exec "$CLONE" /bin/zsh -lc "/usr/bin/log show --last 1h --style compact --info \
    --predicate 'process BEGINSWITH \"WebView\"' > $GUEST_RESULTS/app.log 2>&1; \
  cp ~/Library/Application\\ Support/*/CEF/chrome_debug.log $GUEST_RESULTS/ 2>/dev/null; \
  mkdir -p $GUEST_RESULTS/crashes; cp ~/Library/Logs/DiagnosticReports/WebView*.ips $GUEST_RESULTS/crashes/ 2>/dev/null; true"

# --- Results back ----------------------------------------------------------

mkdir -p "$RESULTS_DIR"
log "Pulling results into $RESULTS_DIR"
tart exec "$CLONE" /bin/zsh -lc "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR"

print ""
grep -E "^Test case '.*' (passed|failed)|TEST (SUCCEEDED|FAILED)|Testing failed" "$RESULTS_DIR/xcodebuild.log" | tail -40 || true
print ""
if (( test_rc == 0 )); then
  log "RESULT: TEST SUCCEEDED"
else
  log "RESULT: TEST FAILED (exit $test_rc)"
fi
log "Result bundle: $RESULTS_DIR/Tests.xcresult"
log "Full log:      $RESULTS_DIR/xcodebuild.log"

exit "$test_rc"
