#!/bin/zsh
# Maintainer tool: move the package to a CEF version and produce its release artifact.
#
#   Scripts/update_cef.sh                 # uses CEF_VERSION below
#   CEF_VERSION=… Scripts/update_cef.sh   # try another build
#
# 1. Downloads the CEF "Standard Distribution" into CEF/ (git-ignored) if it is not there yet.
# 2. Vendors CEF's headers and C++ wrapper sources into Sources/CEFDLLWrapper (committed).
# 3. Builds Frameworks/ChromiumEmbeddedFramework.xcframework (git-ignored), which Package.swift
#    uses instead of the release download when present.
# 4. Zips it to .build/release/ and prints the checksum to paste into Package.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned CEF build (https://cef-builds.spotifycdn.com/index.html, macOS ARM64 "Standard Distribution").
CEF_VERSION="${CEF_VERSION:-154.0.34+g14c5a08+chromium-154.0.8037.98}"
CEF_PLATFORM="macosarm64"
CEF_DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
CEF_DIR="$ROOT/CEF/$CEF_DIST"

FW_NAME="Chromium Embedded Framework"
XCFW_NAME="ChromiumEmbeddedFramework.xcframework"
XCFW="$ROOT/Frameworks/$XCFW_NAME"
RELEASE_DIR="$ROOT/.build/release"
WRAPPER_DIR="$ROOT/Sources/CEFDLLWrapper"

# ─── 1. Download ────────────────────────────────────────────────────────────────

if [[ ! -d "$CEF_DIR" ]]; then
    echo "⬇️  Downloading $CEF_DIST"
    mkdir -p "$ROOT/CEF"
    url="https://cef-builds.spotifycdn.com/${CEF_DIST//+/%2B}.tar.bz2"
    curl -fL --progress-bar -o "$ROOT/CEF/$CEF_DIST.tar.bz2" "$url"
    tar -xjf "$ROOT/CEF/$CEF_DIST.tar.bz2" -C "$ROOT/CEF"
    rm "$ROOT/CEF/$CEF_DIST.tar.bz2"
fi

# ─── 2. Vendor the C++ wrapper ──────────────────────────────────────────────────

echo "📦 Vendoring headers and libcef_dll into Sources/CEFDLLWrapper"
# module.modulemap is ours, not CEF's; keep it.
rsync -a --delete --filter 'P module.modulemap' "$CEF_DIR/include/" "$WRAPPER_DIR/include/"
rsync -a --delete --exclude CMakeLists.txt "$CEF_DIR/libcef_dll/" "$WRAPPER_DIR/libcef_dll/"
cp "$CEF_DIR/LICENSE.txt" "$WRAPPER_DIR/LICENSE.txt"

# ─── 3. XCFramework ─────────────────────────────────────────────────────────────
#
# Assembled by hand: `xcodebuild -create-xcframework` replaces the versioned framework's symlinks
# with copies, which duplicates the 230 MB binary and breaks code signing.

echo "📚 Building $XCFW_NAME"
rm -rf "$ROOT/Frameworks"
fw="$XCFW/macos-arm64/$FW_NAME.framework"
mkdir -p "$fw/Versions/A"

# CEF ships a flat framework; macOS signing needs the versioned layout.
ditto "$CEF_DIR/Release/$FW_NAME.framework/$FW_NAME" "$fw/Versions/A/$FW_NAME"
ditto "$CEF_DIR/Release/$FW_NAME.framework/Resources" "$fw/Versions/A/Resources"
ditto "$CEF_DIR/Release/$FW_NAME.framework/Libraries" "$fw/Versions/A/Libraries"
ln -s A "$fw/Versions/Current"
ln -s "Versions/Current/$FW_NAME" "$fw/$FW_NAME"
ln -s Versions/Current/Resources "$fw/Resources"
ln -s Versions/Current/Libraries "$fw/Libraries"

# Xcode signs the bare binary path, so the install name must point into Versions/A.
install_name_tool -id "@rpath/$FW_NAME.framework/Versions/A/$FW_NAME" "$fw/Versions/A/$FW_NAME"
# Ad-hoc sign so `swift test` can load it; the host app re-signs it with its own team when it embeds it.
codesign --force --sign - "$fw/Versions/A"

cat > "$XCFW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$FW_NAME.framework/Versions/A/$FW_NAME</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>$FW_NAME.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

# ─── 4. Release zip ─────────────────────────────────────────────────────────────

echo "🗜  Zipping"
mkdir -p "$RELEASE_DIR"
zip_path="$RELEASE_DIR/$XCFW_NAME.zip"
rm -f "$zip_path"
# ditto keeps the symlinks in the archive. Without --norsrc/--noextattr it also stores extended
# attributes as ._* files, which unzip turns into real files that break code signing.
xattr -cr "$XCFW"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$XCFW" "$zip_path"
checksum="$(swift package --package-path "$ROOT" compute-checksum "$zip_path")"

cat <<EOF

✅ CEF $CEF_VERSION
   Frameworks/$XCFW_NAME (used by local builds)
   $zip_path ($(du -h "$zip_path" | cut -f1))

To release: set releaseTag in Package.swift (<CEF major>.<CEF patch>.<revision>) and
   cefChecksum = "$checksum"
then tag that commit and upload the zip to the GitHub release for the tag.
EOF
