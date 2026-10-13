#!/bin/zsh
# notarize.sh — build, sign, notarize and staple the demo app with one command.
#
#   Scripts/notarize.sh
#
# Uses the Apple account Xcode is signed into (Xcode → Settings → Accounts), the same way Organizer's
# Distribute App does. No notarytool profile, app-specific password or API key is needed. The
# notarized app lands in build/notarized/WebView.app.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="XV8BAAVZ6V"
OUT="$REPO/build/notarized"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cefwebview-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

log() { print -r -- "==> $*"; }

log "Archiving a Release build signed with Developer ID"
xcodebuild -project "$REPO/WebView/WebView.xcodeproj" -scheme WebView -configuration Release \
  -derivedDataPath "$WORK/DerivedData" -archivePath "$WORK/WebView.xcarchive" archive \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" DEVELOPMENT_TEAM="$TEAM" \
  > "$WORK/archive.log" 2>&1 || { tail -30 "$WORK/archive.log"; exit 1; }

cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

log "Uploading to Apple's notary service"
xcodebuild -exportArchive -archivePath "$WORK/WebView.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/upload" -allowProvisioningUpdates > "$WORK/upload.log" 2>&1 \
  || { tail -30 "$WORK/upload.log"; exit 1; }

log "Waiting for Apple (usually 1-3 minutes)"
for attempt in {1..40}; do
  rm -rf "$WORK/notarized"
  if xcodebuild -exportNotarizedApp -archivePath "$WORK/WebView.xcarchive" -exportPath "$WORK/notarized" \
      > "$WORK/notarized.log" 2>&1; then
    break
  fi
  (( attempt < 40 )) || { tail -30 "$WORK/notarized.log"; exit 1; }
  sleep 30
done

rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$WORK/notarized/WebView.app" "$OUT/WebView.app"

xcrun stapler validate "$OUT/WebView.app" >/dev/null
spctl --assess --type execute "$OUT/WebView.app"
log "Notarized and stapled: $OUT/WebView.app"
