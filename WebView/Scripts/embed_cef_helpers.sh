#!/bin/bash
# Build SPM helper executables and embed CEF-required Helper.app bundles into WebView.app/Contents/Frameworks/.

set -euo pipefail

PACKAGE_ROOT="${SRCROOT}/.."
SWIFT_CFG=$(echo "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')
case "${SWIFT_CFG}" in
  debug|release) ;;
  *) SWIFT_CFG="debug" ;;
esac

echo "embed_cef_helpers: swift build -c ${SWIFT_CFG} (package: ${PACKAGE_ROOT})"
cd "${PACKAGE_ROOT}"
xcrun swift build -c "${SWIFT_CFG}"

# Ask SwiftPM where it put the products; the .build layout differs across toolchain versions.
BUILD_BIN="$(xcrun swift build -c "${SWIFT_CFG}" --show-bin-path)"
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
  local exe_name="$4"
  cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${exe_name}</string>
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
  local exe_name="$3"
  local bundle_id="$4"
  local display_name="$5"
  local app_path="${FW_DIR}/${folder_name}.app"
  local macos_dir="${app_path}/Contents/MacOS"

  # Verify source executable exists and is not empty
  if [[ ! -f "${exe_src}" ]]; then
    echo "error: Source executable not found: ${exe_src}"
    exit 1
  fi

  local exe_size=$(stat -f%z "${exe_src}" 2>/dev/null || stat -c%s "${exe_src}" 2>/dev/null || echo 0)
  if [[ ${exe_size} -eq 0 ]]; then
    echo "error: Source executable is empty (0 bytes): ${exe_src}"
    exit 1
  fi

  mkdir -p "${macos_dir}"
  cp -f "${exe_src}" "${macos_dir}/${exe_name}"
  chmod +x "${macos_dir}/${exe_name}"

  # Verify copied executable is not empty
  local copied_size=$(stat -f%z "${macos_dir}/${exe_name}" 2>/dev/null || stat -c%s "${macos_dir}/${exe_name}" 2>/dev/null || echo 0)
  if [[ ${copied_size} -eq 0 ]]; then
    echo "error: Failed to copy executable or file is empty: ${macos_dir}/${exe_name}"
    exit 1
  fi

  write_plist "${app_path}/Contents/Info.plist" "${bundle_id}" "${display_name}" "${exe_name}"

  # Verify Info.plist was created and is not empty
  if [[ ! -f "${app_path}/Contents/Info.plist" ]] || [[ ! -s "${app_path}/Contents/Info.plist" ]]; then
    echo "error: Failed to create Info.plist for ${folder_name}: ${app_path}/Contents/Info.plist"
    exit 1
  fi
}

# Create entitlements file (temp location, not in bundle)
ENTITLEMENTS_FILE="/tmp/webview_entitlements_$$.plist"
write_entitlements "${ENTITLEMENTS_FILE}"

install_bundle "WebView Helper" "${HELPER_GEN}" "WebView Helper" "co.sstools.WebView.helper" "WebView Helper"
install_bundle "WebView Helper (GPU)" "${HELPER_GEN}" "WebView Helper (GPU)" "co.sstools.WebView.helper.gpu" "WebView Helper GPU"
install_bundle "WebView Helper (Renderer)" "${HELPER_REN}" "WebView Helper (Renderer)" "co.sstools.WebView.helper.renderer" "WebView Helper Renderer"

sign_app() {
  local app="$1"
  local entitlements="$2"

  # Verify bundle structure exists
  if [[ ! -d "${app}/Contents/MacOS" ]]; then
    echo "error: Bundle structure missing: ${app}/Contents/MacOS"
    exit 1
  fi

  # Find the executable by reading Info.plist CFBundleExecutable key
  local exe_name=$(defaults read "${app}/Contents/Info" CFBundleExecutable 2>/dev/null)
  if [[ -z "${exe_name}" ]]; then
    echo "error: Could not determine executable name from Info.plist for ${app}"
    exit 1
  fi

  local exe_path="${app}/Contents/MacOS/${exe_name}"
  if [[ ! -f "${exe_path}" ]]; then
    echo "error: Bundle executable not found: ${exe_path}"
    exit 1
  fi

  local exe_size=$(stat -f%z "${exe_path}" 2>/dev/null || stat -c%s "${exe_path}" 2>/dev/null || echo 0)
  if [[ ${exe_size} -eq 0 ]]; then
    echo "error: Bundle executable is empty (0 bytes): ${exe_path}"
    exit 1
  fi

  # Determine code sign identity - use development identity if available, fallback to ad-hoc
  local sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"

  # Hardened runtime enables library validation, which rejects ad-hoc signed CEF (no Team ID),
  # so only opt into it when signing with a real identity.
  local runtime_opts=(--options runtime)
  if [[ "${sign_identity}" == "-" ]]; then
    runtime_opts=()
  fi

  echo "Code signing ${app} with identity: '${sign_identity}'"

  # Remove existing signatures before re-signing (required for clean rebuilds)
  echo "  Removing existing signatures from executable and bundle..."
  codesign --remove-signature "${exe_path}" 2>/dev/null || true
  codesign --remove-signature "${app}" 2>/dev/null || true

  # Sign the executable with entitlements (MUST be done before signing the bundle)
  echo "  Signing executable: ${exe_path}"
  if ! codesign --force --sign "${sign_identity}" --entitlements "${entitlements}" \
    --timestamp=none ${runtime_opts[@]+"${runtime_opts[@]}"} "${exe_path}"; then
    echo "error: Failed to code sign executable: ${exe_path}"
    exit 1
  fi

  # Sign the app bundle with entitlements
  echo "  Signing bundle: ${app}"
  if ! codesign --force --sign "${sign_identity}" --entitlements "${entitlements}" \
    --timestamp=none ${runtime_opts[@]+"${runtime_opts[@]}"} "${app}"; then
    echo "error: Failed to code sign bundle: ${app}"
    exit 1
  fi

  # Verify entitlements were embedded
  echo "  Verifying signature:"
  if ! codesign -dv "${exe_path}" 2>&1 | head -15; then
    echo "error: Code signature verification failed: ${exe_path}"
    exit 1
  fi
}

sign_app "${FW_DIR}/WebView Helper.app" "${ENTITLEMENTS_FILE}"
sign_app "${FW_DIR}/WebView Helper (GPU).app" "${ENTITLEMENTS_FILE}"
sign_app "${FW_DIR}/WebView Helper (Renderer).app" "${ENTITLEMENTS_FILE}"

# Clean up temp entitlements file
rm -f "${ENTITLEMENTS_FILE}"

# Final validation: verify all bundles are properly created
echo ""
echo "Final validation:"
for bundle in "WebView Helper.app" "WebView Helper (GPU).app" "WebView Helper (Renderer).app"; do
  bundle_path="${FW_DIR}/${bundle}"

  if [[ ! -d "${bundle_path}" ]]; then
    echo "error: Bundle directory missing: ${bundle_path}"
    exit 1
  fi

  # Read executable name from Info.plist
  exe_name=$(defaults read "${bundle_path}/Contents/Info" CFBundleExecutable 2>/dev/null)
  if [[ -z "${exe_name}" ]]; then
    echo "error: Could not determine executable name from Info.plist for ${bundle}"
    exit 1
  fi

  exe_path="${bundle_path}/Contents/MacOS/${exe_name}"
  if [[ ! -f "${exe_path}" ]]; then
    echo "error: Bundle executable missing: ${exe_path}"
    exit 1
  fi

  exe_size=$(stat -f%z "${exe_path}" 2>/dev/null || stat -c%s "${exe_path}" 2>/dev/null || echo 0)
  if [[ ${exe_size} -eq 0 ]]; then
    echo "error: Bundle executable is empty (0 bytes): ${exe_path}"
    exit 1
  fi

  plist_path="${bundle_path}/Contents/Info.plist"
  if [[ ! -f "${plist_path}" ]] || [[ ! -s "${plist_path}" ]]; then
    echo "error: Bundle Info.plist missing or empty: ${plist_path}"
    exit 1
  fi

  echo "✅ ${bundle} → ${exe_name} (${exe_size} bytes)"
done

echo ""
echo "embed_cef_helpers: done."
