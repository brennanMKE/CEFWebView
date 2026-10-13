# Making CEFWebView Reusable

CEFWebView is not yet reusable. It runs one Chromium browser inside the WebView demo app, but another Mac app cannot add it as a package and get a working web view. Six workstreams close that gap. Four of them (multiple browsers, distribution, host-app integration and production defaults) block any outside use.

**Goal:** a developer adds the package by version in Xcode, runs one setup step, drops `CEFWebView` into SwiftUI, and gets a Chromium view that signs, notarizes and ships. Today that takes a manual CEF download, a local build, three custom build phases, and settings that are unsafe to ship.

## Current state

As of commit `2771216` on `main`, the demo app loads pages reliably on CEF 154.0.34 (Chromium 154.0.8037.98), built with Xcode 27 and Swift 6.4.

**What works**

- `CEFWebView(url:state:)`, a SwiftUI view bound to a URL and an observable `CEFWebViewState`.
- State: loading, title, current URL, back/forward availability, and helper-process status.
- Actions: load a URL, reload, back, forward.
- Helper apps (main, GPU, renderer) built by SwiftPM, then embedded and signed by a build script.

**What blocks reuse**

| Area | Blocker | Where |
| --- | --- | --- |
| Browsers | One global browser and client; a second view takes over the first | `CEFWrapper.mm` (`g_browser`, `g_client`) |
| Packaging | `unsafeFlags` makes SwiftPM reject the package as a versioned dependency | `Package.swift` |
| Packaging | CEF binaries live in a git-ignored `Frameworks/` folder built locally | `build_cpp.sh`, `.gitignore` |
| Host app | Three run-script phases, custom search paths, user-script sandboxing off | `WebView.xcodeproj`, `Build.xcconfig` |
| Host app | Helper names and bundle IDs hardcoded to `WebView` / `co.sstools.WebView` | `embed_cef_helpers.sh` |
| API | No JavaScript, messaging, navigation policy, pop-ups or downloads; `estimatedProgress` is never set | `CEFWrapper.h`, `CEFWebViewState.swift` |
| Defaults | GPU off, sandbox off, verbose logging, unencrypted cookies, 4 Hz state polling | `CEFWrapper.mm`, `CEFBridge.swift` |
| Quality | One empty test; `swift test` does not link | `Tests/` |

## Workstream 1: Multiple browsers

Each `CEFWebView` must own its own browser. Today a second view overwrites the global browser, and both views read the same state. Fix this first, because every API added later would otherwise be built on the singleton.

- Replace `g_browser` and `g_client` with one `ChromiumClient` per view. Expose it as an Objective-C++ object (for example `CEFBrowserHandle`) instead of class methods on `CEFWrapper`.
- Move `loadURL`, `reload`, `goBack`, `goForward`, `isLoading`, `currentTitle` and the rest onto that object.
- Keep process-wide work in one place: `CefInitialize`, the message pump, `CefShutdown`, and helper-status tracking.
- Close browsers properly: call `CloseBrowser` from `dismantleNSView`, wait for `OnBeforeClose`, and run `CefShutdown` only after the last browser closes and the app is quitting.
- Replace `CEFApplication.activeBrowserHost` with a per-host route for load errors and helper failures.

**Done when:** two windows each show a different site with independent titles, history and loading state, and closing one leaves the other working.

**Status (2026-10-12):** implemented. `CEFBrowserHandle` owns one browser and reports CEF callbacks to a main-actor delegate; `CEFWrapper` keeps only process-wide work and a registry of open browsers. `CEFWrapper.shutdown` closes any remaining browsers and waits for `OnBeforeClose` before `CefShutdown`. Also fixed along the way: Chromium's `CrAppProtocol` is now provided on `NSApplication` (SwiftUI owns the app class, and closing a browser threw an unrecognized-selector exception), and `OnRenderProcessTerminated` now matches the CEF 154 signature so it actually fires. Verified: two windows create two browsers, closing one leaves the other running, and quitting closes both cleanly. Verified by the `browsersKeepIndependentStateAndHistory` integration test: two browsers keep separate titles, history and JavaScript state, and closing one leaves the other working.

## Workstream 2: Distribution

The package must resolve by version with no local CEF build. That means shipping CEF as a prebuilt binary target and removing every `unsafeFlags`, which SwiftPM rejects in versioned dependencies.

- **CEF framework:** a release script packages `Chromium Embedded Framework.framework` (in the versioned layout `build_cpp.sh` already produces) into an XCFramework zip. Publish it as a GitHub release asset and reference it with `.binaryTarget(url:checksum:)`. It is about 320 MB uncompressed.
- **C++ wrapper:** either ship `libcef_dll_wrapper` as a second static XCFramework, or compile its sources (included in the CEF distribution) as a regular C++ target in the package. Compiling from source avoids keeping two binaries in step.
- **Compiler flags:** replace `-std=c++20` with `cxxLanguageStandard: .cxx20`, and point header search paths at folders inside the package instead of `../../Frameworks`.
- **Helper rpaths:** drop the `-rpath` linker flags from the helper targets and set rpaths with `install_name_tool` when the helpers are embedded (Workstream 3).
- **Versioning:** the package version tracks CEF (for example `154.0.34-1`). `build_cpp.sh` becomes a maintainer-only release tool.
- **Open question:** Apple silicon only (as today), or universal? An x86_64 slice roughly doubles the download.

**Done when:** a new Xcode project adds the package by version from GitHub and builds without running any script by hand.

**Status (2026-10-12):** done. `Package.swift` has no `unsafeFlags`. `libcef_dll_wrapper` and CEF's headers are vendored in `Sources/CEFDLLWrapper` and compiled as a C++ target. Nothing links the CEF framework except the app: `CefScopedLibraryLoader` opens it at runtime, so the helper needs no rpaths. `Scripts/update_cef.sh` replaces `build_cpp.sh`; it vendors the sources and builds the XCFramework zip and checksum. The XCFramework is assembled by hand because `xcodebuild -create-xcframework` replaces the versioned framework's symlinks with copies. The zip is written without `._*` AppleDouble files, which would break signing. A local `Frameworks/ChromiumEmbeddedFramework.xcframework` takes precedence over the download. Versions are `<CEF major>.<CEF patch>.<revision>` (CEF 154.0.34 → `154.34.0`), not `154.0.34-1`, because SwiftPM's normal version requirements skip pre-release versions. `swift test` now links and runs. Published as the `154.34.0` GitHub release (`154.34.1` adds a package-only fix and reuses that release's zip, since `releaseTag` names the release that holds the artifact, not the package version). Verified: a copy of the demo project that adds the package from GitHub with "Up to Next Major" from `154.34.0` resolves, downloads and checks the artifact, builds, passes `codesign --verify --deep --strict` with a team identity, and loads pages.

## Workstream 3: Host app integration

Embedding should be one build step configured by the host app's name and bundle ID, not three hand-copied run scripts.

CEF requires this bundle layout:

```
MyApp.app/Contents/
├── MacOS/MyApp
└── Frameworks/
    ├── Chromium Embedded Framework.framework   (versioned: Versions/A, Current → A)
    ├── MyApp Helper.app
    ├── MyApp Helper (GPU).app
    ├── MyApp Helper (Renderer).app
    └── MyApp Helper (Plugin).app               (only if plugins are used)
```

- **One script** (`cef-embed`) replaces "Copy CEF", "Fix CEF Framework" and "Embed CEF Helpers". It copies the framework with its symlinks intact (`ditto` or `rsync -a`, not a Copy Files phase, which flattens symlinks), creates the helper bundles, sets rpaths, and signs in the right order: helpers' executables, then helper bundles, then the framework, then the app.
- **Names from the host:** derive helper names from `PRODUCT_NAME` and bundle IDs from `PRODUCT_BUNDLE_IDENTIFIER` (`<id>.helper`, `<id>.helper.gpu`, `<id>.helper.renderer`). Write `browser_subprocess_path` from the same values instead of hardcoding `WebView Helper`.
- **Delivery:** ship the script inside the package and document one run-script phase that calls it. A SwiftPM build-tool plugin cannot write into the app bundle, so a script phase is still needed; keep it to one line.
- **Signing:** use `EXPANDED_CODE_SIGN_IDENTITY` and the host's team. Hardened runtime is on for real identities and off for ad-hoc (already the case). Helpers need `com.apple.security.cs.allow-jit`. Drop `get-task-allow` in Release.
- **Sandboxing:** `ENABLE_USER_SCRIPT_SANDBOXING = NO` is required while the script writes into the bundle; declare the script's inputs and outputs so it does not run on every build.
- **Notarization:** document a Developer ID build and notarization of an app that embeds CEF.

**Done when:** a fresh macOS app target, with only the package dependency and the one script phase, runs, signs with a team identity, and passes `codesign --verify --deep --strict` and notarization.

**Status (2026-10-13):** done. Because `CEFWebView` depends on the framework's binary target, Xcode embeds and signs `Chromium Embedded Framework.framework` itself, and keeps its symlinks. `Scripts/cef-embed` does the rest: it builds `CEFHelper` with SwiftPM in a clean environment, then installs and signs `<App> Helper`, `(GPU)`, `(Renderer)` and `(Alerts)`. Without the Alerts helper, Chromium relaunched its notification service forever with backoff. The script takes names from `EXECUTABLE_NAME` and `PRODUCT_BUNDLE_IDENTIFIER`, uses hardened runtime only with a real identity, adds a secure timestamp for archives, and includes `get-task-allow` only in Debug. It skips unchanged helpers. When a helper does change, it touches the app's `Info.plist`, because otherwise Xcode doesn't re-sign the app and the seal breaks. The phase is always-run rather than declaring inputs and outputs, because the helper's real inputs are the package sources. `CEFWrapper` derives `browser_subprocess_path` from the main executable's name. Verified: a clean Debug build and a Release build renamed to `Browsy` / `com.example.browsy` both pass `codesign --verify --deep --strict` with a team identity and load pages. Notarization works: `Scripts/notarize.sh` archives the demo with Developer ID, notarizes it through the account Xcode is signed into, and staples it; `spctl` reports "Notarized Developer ID". In a remote checkout the helper's nested `swift build` resolves the framework artifact too. It comes from SwiftPM's shared download cache, so the zip is downloaded only once, but it is extracted a second time (about 320 MB in the target's temp folder). That build also treats the package as a root package, so `cef-embed` passes `-Xcc -w` to keep CEF's vendored code from adding about 400 warnings to the host app's build log.

## Workstream 4: API surface

The view needs the basics developers expect from `WKWebView` before it is worth adopting.

| Capability | Proposed API | CEF hook |
| --- | --- | --- |
| Run JavaScript, get a result | `state.evaluateJavaScript(_:) async throws -> Any?` | `ExecuteJavaScript` + a process message back from the renderer |
| JavaScript → Swift messages | `onMessage(name:)` handler; `window.cefWebView.postMessage(...)` in the page | `CefMessageRouter` (browser + renderer side) |
| Allow or block navigation | `navigationPolicy` closure (URL, is main frame, user gesture) | `CefRequestHandler::OnBeforeBrowse` |
| Pop-ups and new windows | `onNewWindow` closure: open in place, new view, or block | `CefLifeSpanHandler::OnBeforePopup` |
| Load progress | `estimatedProgress` (exists, never set) | `CefDisplayHandler::OnLoadingProgressChange` |
| Load errors | `lastError` with code and text (generalize the renderer-failure fields) | `CefLoadHandler::OnLoadError` |
| Downloads | `onDownload` closure with destination and progress | `CefDownloadHandler` |
| File pickers | `<input type=file>` uses `NSOpenPanel` | `CefDialogHandler` |
| Find in page, zoom | `find(_:)`, `zoomLevel` | `CefBrowserHost::Find`, `SetZoomLevel` |
| Cookies and storage | Clear data; separate profiles per view | `CefCookieManager`, `CefRequestContext` |
| User agent | Configurable instead of the hardcoded string | `CefSettings.user_agent` |

- Group configuration into a `CEFWebViewConfiguration` passed at creation (profile path, user agent, logging, GPU), so global settings stop living in `CEFWrapper.mm`.
- Trim `CEFWebViewState`: the per-helper flags are debugging aids; replace them with one `processStatus` value.

**Done when:** the demo app uses JavaScript evaluation, a message handler, a navigation policy and pop-up handling, and all are covered by tests.

**Status (2026-10-12):** done. `CEFWebViewState` has `evaluateJavaScript(_:)` (promises awaited, results JSON-decoded), `setMessageHandler(_:_:)` for `window.cefWebView.postMessage(name, body)` from any frame, `navigationPolicy`, `newWindowPolicy` (CEF's unmanaged pop-up windows are never opened), `downloadPolicy` and `downloads`, `find(_:)`, `pageZoom`, `lastError`, `processStatus` (replacing the per-helper flags), `stopLoading()` and `loadHTML(_:)`; `CEFConfiguration.userAgent` and `CEFApplication.deleteAllCookies()`. The renderer side lives in `CEFRenderProcess.mm`. The demo uses all of it. 15 integration tests in `WebViewTests` cover it and run only in a Tart VM (`Scripts/run-tests-vm.sh`, [TESTING_IN_TART.md](TESTING_IN_TART.md)); package unit tests cover the pure Swift parts. Not done: file pickers (CEF's default dialog is untested), separate profiles per view, and a per-view `CEFWebViewConfiguration`; process-wide settings stay in `CEFConfiguration`. Known CEF 154 issue: a `srcdoc` iframe in a `data:` URL page crashes the renderer.

## Workstream 5: Production defaults

Several settings were chosen to get the demo running and are unsafe or slow in a shipping app.

| Setting | Today | Ship default |
| --- | --- | --- |
| GPU | ~~`--disable-gpu`, software rendering~~ Done: on, `CEFConfiguration.gpuEnabled` turns it off | GPU on; keep a configuration flag to turn it off |
| Chromium sandbox | ~~`--no-sandbox` on helpers~~ Done: on, `sandboxEnabled` turns it off | Sandbox on; confirm the helpers' entitlements allow it |
| Logging | ~~`LOGSEVERITY_VERBOSE`, `--v=3`, `enable-logging`~~ Done: warnings, `verboseLogging` opts in | Warnings and errors; verbose only by configuration |
| Cookie encryption | `--use-mock-keychain` (cookies unencrypted on disk); `useSystemKeychain` opts in | Real keychain under a stable team signature; mock keychain only for ad-hoc debug builds |
| Profile path | ~~`~/Library/Caches/com.chromium.webview` for every app~~ Done | `~/Library/Application Support/<bundle id>/CEF`, since Caches can be purged |
| State updates | ~~Swift polls CEF 4 times a second~~ Done: CEF callbacks post to the main actor | CEF callbacks post to the main actor; remove the timer |
| Message pump | Scheduled work plus a 30 Hz fallback timer | Keep; this matches CEF's own Mac sample |
| `CefShutdown` | Called when the view goes away | Called once at app termination (Workstream 1) |

**Done when:** a Release build runs with the GPU and sandbox on, logs only warnings, keeps cookies across launches without keychain prompts, and uses under 1% CPU while idle.

**Status (2026-10-13):** done. The sandbox needed no new entitlements. CEF 154 ships it as `libcef_sandbox.dylib` in the framework's `Libraries` folder; each helper loads it with `CefScopedSandboxContext` before loading CEF. Xcode signs only the framework's main binary, so library validation rejected that dylib's ad-hoc signature. `cef-embed` now signs the framework's dylibs with the app's identity and re-seals the framework. `sandbox_check` confirms the GPU, network, storage and renderer processes are sandboxed; the browser process is not, as in Chrome. Settings are passed as `CEFConfiguration` to `CEFApplication.initialize(_:)`. The profile was never persisted before: `cache_path` was empty, so CEF ran in incognito mode; it now equals `root_cache_path`. The real keychain is opt-in rather than the default because Chromium's item name, "Chromium Safe Storage", is fixed in the CEF binary and shared by every CEF app, so a second app (or the same app under another bundle ID) gets a login-password prompt; there is no CEF setting to rename it. Notification banners: Chromium started its macOS notification service in the Alerts helper, and `usernoted` logged a permission request for both the app and the helper, which macOS shows as "Notifications may include alerts…" banners. `CEFConfiguration.systemNotificationsEnabled` (default off) now passes `--disable-notifications` and disables the `SystemNotifications` feature; the Alerts helper no longer starts and `usernoted` logs no requests. Pages see notification permission denied. Idle CPU, Release build on a static page in a Tart VM, measured over a minute after two minutes' settling: 0.62% for the app, 0.02% for the helpers. The app wakes about 30 times a second for the pump's fallback timer; a 10 Hz fallback measured the same CPU, so it stays at the rate CEF's own sample uses.

## Workstream 6: Testing, documentation and CI

- **Tests:** fix linking for `swift test`, which needs a signed framework copy or a test host app. Add unit tests for state mapping and navigation-key logic. Add a UI-test target in the demo app that loads a local HTML fixture (no network) and checks title, back/forward, JavaScript evaluation and two simultaneous views.
- **CI:** a GitHub Actions macOS job that downloads the pinned CEF, builds the package and demo app ad-hoc, and runs the tests. A separate release workflow builds the XCFramework, computes the checksum, and updates `Package.swift`.
- **Docs:** replace the placeholder `README.md` with an install guide (dependency, script phase, entitlements, minimal SwiftUI sample) and an API reference. Fold the useful parts of `IMPLEMENTATION_GUIDE.md` and `JIT.md` into it and delete what is out of date.
- **Cleanup:** remove the debug scripts (`capture_logs.sh`, `diagnose_renderer.sh`, `fix_cef_framework.sh` once Workstream 3 replaces it) from the package root, or move them to `Scripts/dev/`.
- **CEF updates:** a documented process for moving to a new CEF version: bump `CEF_VERSION`, rebuild, run the tests, publish a release.

**Done when:** every pull request runs CI, and a new user can follow the README to a working view in a fresh app.

**Status (2026-10-13):** done, with CI not yet run on GitHub. `.github/workflows/ci.yml` runs `swift test` and the demo's integration and UI tests (ad hoc signed) on every push to `main` and every pull request, on the `xcode-27` preview runner. `.github/workflows/cef-release.yml` (manual) builds the XCFramework zip, attaches it to a draft release and prints the `Package.swift` lines. The README covers installation (including entitlements), configuration, the API and shipping; [ARCHITECTURE.md](ARCHITECTURE.md) replaces `IMPLEMENTATION_GUIDE.md` and `JIT.md`; [UPDATING_CEF.md](UPDATING_CEF.md) is the CEF update and release process. The debug scripts moved to `Scripts/dev/`, with `idle-probe.sh`, which measures idle CPU and notification registration in a Tart VM (`Scripts/run-tests-vm.sh --guest-script`).

## Order and milestones

| Milestone | Workstreams | Exit criteria |
| --- | --- | --- |
| M1: Correct core (done) | 1, and the state-callback part of 5 | Two independent views; no polling; clean shutdown |
| M2: Installable (done) | 2, 3 | Fresh app adds the package by version and runs with one script phase |
| M3: Shippable (done) | rest of 5, notarization from 3 | Release build with GPU and sandbox on, notarized |
| M4: Useful API (done) | 4 | JavaScript, messaging, navigation policy, pop-ups, progress |
| M5: Maintained (done) | 6 | CI on every PR, README install guide, documented CEF update process |

M1 comes first because Workstreams 2 to 4 all build on the per-browser object. M2 and M3 can run in parallel once M1 lands.

**Reusable means:** M1 through M3 are done. M4 and M5 make it pleasant to adopt and keep current.
