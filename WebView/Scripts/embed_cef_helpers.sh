#!/bin/bash
# Build SPM helper executables and embed CEF-required Helper.app bundles into WebView.app/Contents/Frameworks/.

set -euo pipefail

PACKAGE_ROOT="${SRCROOT}/.."
SWIFT_CFG=$(echo "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')
case "${SWIFT_CFG}" in
  debug|release) ;;
  *) SWIFT_CFG="debug" ;;
esac

ARCH="$(uname -m)"
echo "embed_cef_helpers: swift build -c ${SWIFT_CFG} (package: ${PACKAGE_ROOT})"
cd "${PACKAGE_ROOT}"
xcrun swift build -c "${SWIFT_CFG}"

BUILD_BIN="${PACKAGE_ROOT}/.build/${ARCH}-apple-macosx/${SWIFT_CFG}"
HELPER_GEN="${BUILD_BIN}/CEFHelper"
HELPER_REN="${BUILD_BIN}/CEFHelperRenderer"

if [[ ! -f "${HELPER_GEN}" ]] || [[ ! -f "${HELPER_REN}" ]]; then
  echo "error: Missing ${HELPER_GEN} or ${HELPER_REN} after swift build."
  exit 1
fi

FW_DIR="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/../Frameworks"
mkdir -p "${FW_DIR}"

write_plist() {
  local plist="$1"
  local bundle_id="$2"
  local bundle_display="$3"
  cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>WebView Helper</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleName</key>
	<string>${bundle_display}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
</dict>
</plist>
EOF
}

write_entitlements() {
  local entitlements="$1"
  cat > "${entitlements}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Required for Chromium's V8 JavaScript engine (JIT compilation) -->
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<!-- Required for Chromium helper process IPC via Mach task ports -->
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<!-- Allows helper process to be debugged -->
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
}

install_bundle() {
  local folder_name="$1"
  local exe_src="$2"
  local bundle_id="$3"
  local display_name="$4"
  local app_path="${FW_DIR}/${folder_name}.app"
  local macos_dir="${app_path}/Contents/MacOS"
  mkdir -p "${macos_dir}"
  cp -f "${exe_src}" "${macos_dir}/WebView Helper"
  chmod +x "${macos_dir}/WebView Helper"
  write_plist "${app_path}/Contents/Info.plist" "${bundle_id}" "${display_name}"
  write_entitlements "${app_path}/Contents/Info.plist.entitlements"
}

install_bundle "WebView Helper" "${HELPER_GEN}" "co.sstools.WebView.helper" "WebView Helper"
install_bundle "WebView Helper (GPU)" "${HELPER_GEN}" "co.sstools.WebView.helper.gpu" "WebView Helper GPU"
install_bundle "WebView Helper (Renderer)" "${HELPER_REN}" "co.sstools.WebView.helper.renderer" "WebView Helper Renderer"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]] && [[ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
  sign_app() {
    local app="$1"
    local entitlements="${app}/Contents/Info.plist.entitlements"
    # Sign the executable with entitlements
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --entitlements "${entitlements}" \
      --timestamp=none --options runtime "${app}/Contents/MacOS/WebView Helper" 2>/dev/null || true
    # Sign the app bundle with entitlements
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --entitlements "${entitlements}" \
      --timestamp=none --options runtime "${app}" 2>/dev/null || true
  }
  sign_app "${FW_DIR}/WebView Helper.app"
  sign_app "${FW_DIR}/WebView Helper (GPU).app"
  sign_app "${FW_DIR}/WebView Helper (Renderer).app"
fi

echo "embed_cef_helpers: done."
