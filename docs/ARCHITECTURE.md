# How CEFWebView works

For contributors and for debugging an app that embeds the package. Using it is covered in the
[README](../README.md).

## Targets

| Target | Language | Role |
| --- | --- | --- |
| `CEFWebView` | Swift | Public API: `CEFWebView` (SwiftUI), `CEFWebViewState`, `CEFApplication`, `CEFConfiguration` and value types. Default MainActor isolation. |
| `CEFWrapper` | Objective-C++ | The bridge to CEF's C++ API. `CEFWrapper` owns process-wide work; `CEFBrowserHandle` owns one browser. `CEFRenderProcess.mm` is the renderer side of JavaScript evaluation and messaging. |
| `CEFDLLWrapper` | C++ | CEF's `libcef_dll_wrapper` and headers, vendored from the CEF distribution by `Scripts/update_cef.sh`. Turns C++ calls into calls on the framework's C API. |
| `ChromiumEmbeddedFramework` | Binary | `Chromium Embedded Framework.framework` (~320 MB), a GitHub release download, or `Frameworks/` when a maintainer has built it locally. |
| `CEFHelper` | Objective-C++ | The one executable behind every helper app. |

Nothing links the CEF framework. `CefScopedLibraryLoader` opens it at runtime, in the app and in
each helper, so neither needs rpaths. `CEFWebView` depends on the binary target only so that Xcode
embeds and signs the framework in the host app.

## Processes

Chromium runs each job in its own process. The app is the browser process; the rest are helper apps
in `Contents/Frameworks`, installed by `Scripts/cef-embed`:

```
MyApp.app/Contents/
├── MacOS/MyApp                                   browser process
└── Frameworks/
    ├── Chromium Embedded Framework.framework     Versions/A, Current → A (Xcode embeds and signs it)
    ├── MyApp Helper.app                          network, storage and other utility processes
    ├── MyApp Helper (GPU).app                    GPU process
    ├── MyApp Helper (Renderer).app               one per site: HTML, CSS, V8
    └── MyApp Helper (Alerts).app                 macOS notification service
```

All four are copies of `CEFHelper` with their own `Info.plist`. Chromium picks the bundle by role
and passes `--type=` to tell the process what it is. CEF finds them from `browser_subprocess_path`,
which `CEFWrapper` derives from the main executable's name. Helpers that are missing or named
wrongly show up as a blank page or as Chromium relaunching a service forever.

The app also calls `CEFApplication.handleSubprocessIfNeeded()` first thing, because Chromium can
launch the main executable itself in a subprocess role.

**Sandbox.** Every helper but the browser process runs in Chromium's sandbox (`sandboxEnabled`).
Before loading CEF, each helper calls `CefScopedSandboxContext::Initialize`, which loads
`libcef_sandbox.dylib` from the framework's `Libraries` folder. Library validation requires that
dylib to carry the app's team signature, so `cef-embed` re-signs the framework's dylibs and then the
framework. This is Chromium's own sandbox, not the App Sandbox, which CEF does not support.

## Threads and the message pump

CEF runs with an external message pump on the main thread, so CEF's UI thread *is* the main thread:

- `OnScheduleMessagePumpWork` schedules `CefDoMessageLoopWork` on the main run loop, and a 30 Hz
  timer backs it up, as in CEF's own macOS sample. Scheduled work alone can stall.
- CEF callbacks (`CefLoadHandler`, `CefDisplayHandler`, `CefRequestHandler`, …) arrive on the main
  thread. `ChromiumClient` forwards them to its `CEFBrowserHandle`, which calls its delegate, the
  Swift `CEFBrowserHost`, which updates `CEFWebViewState`. No polling.
- Policy callbacks such as `navigationPolicy` are synchronous for the same reason: CEF asks on the
  main thread and waits for the answer.
- Never block the main thread waiting for CEF. Tests wait by polling while the run loop keeps
  running.

## Browsers

Each `CEFWebView` creates one `CEFBrowserHandle`, which owns one `ChromiumClient` and one
`CefBrowser`. `CEFWrapper` keeps the process-wide parts: `CefInitialize`, the pump, `CefShutdown`,
helper status, and a registry of open browsers. Browsers are Alloy-style windowed children of the
SwiftUI view's `NSView`.

Closing: `dismantleNSView` calls `CloseBrowser`; the handle lives until `OnBeforeClose`.
`CEFApplication.shutdown()` closes any browsers still open, waits for their `OnBeforeClose`, then calls
`CefShutdown`.

## JavaScript and messages

The renderer side is `CEFRenderProcess.mm`, a `CefRenderProcessHandler` that runs in the Renderer
helper.

- **`window.cefWebView.postMessage(name, body)`** is installed in every frame's V8 context from
  `OnContextCreated`. It JSON-stringifies the body and sends a `CEFWebView.postMessage` process message
  to the browser, which routes it to the handler registered with `setMessageHandler`.
- **`evaluateJavaScript`** sends `CEFWebView.evaluate` with an ID to the main frame. The renderer runs
  the script with `CefV8Context::Eval`, awaits a returned promise through its `then`, and answers with
  `CEFWebView.evaluateResult`: JSON or an error message. Pending evaluations fail when the main frame
  navigates, the browser closes or the renderer dies.
- **User-gesture scripts** (tests only, `@_spi(Testing)`) go through DevTools' `Runtime.evaluate`
  with `userGesture: true`, because Chromium's pop-up blocker ignores ordinary script.

## Pop-ups and navigation

`OnBeforeBrowse` asks `navigationPolicy` for every frame's navigation. `OnBeforePopup` always cancels
the native window CEF would otherwise open (an unmanaged `NSWindow` outside SwiftUI) and then, per
`newWindowPolicy`, loads the URL in place or drops it. To open your own window, open it in the policy
and return `.block`.

## Code signing and entitlements

Chromium's V8 compiles JavaScript to machine code, which the hardened runtime blocks unless the
process has:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.cs.allow-jit` | V8 allocates writable and executable memory for compiled code. Without it the renderer crashes as soon as V8 starts, and pages stay blank. |
| `com.apple.security.cs.allow-unsigned-executable-memory` | V8 writes executable code outside the JIT region in some cases. |

`cef-embed` gives the helpers both; the app needs them in its entitlements file too. Debug builds
also get `get-task-allow`; Release builds and archives do not, and notarization rejects it.

Signing order matters, and `cef-embed` keeps it: framework dylibs, then the framework, then each
helper, then (Xcode) the app. An ad-hoc identity (`-`) turns the hardened runtime off, because
library validation would reject ad-hoc code, and makes the package use the mock keychain, because
the signature changes on every build.

## Profile and logs

- Profile (cookies, local storage, cache): `~/Library/Application Support/<bundle id>/CEF`, or
  `CEFConfiguration.profileDirectory`. `root_cache_path` and `cache_path` both point there; an empty
  `cache_path` would mean incognito.
- Chromium's log: `chrome_debug.log` in the profile, warnings and errors unless `verboseLogging`.
- `CEFWrapper`'s own lines go to the unified log through `NSLog`:
  `log show --last 10m --predicate 'process BEGINSWITH "MyApp"'`.
- Crashed helpers leave reports in `~/Library/Logs/DiagnosticReports/` named after the helper.
- Cookies are unencrypted unless `useSystemKeychain`; see the README for why that is the default.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Blank page, title never set | Helpers missing or misnamed (check `Contents/Frameworks`), or V8 blocked: the helper lacks `allow-jit`. A crash report for `<App> Helper (Renderer)` confirms the second. |
| `Library not loaded … libcef_sandbox.dylib` or a code-signature error in a helper | The framework's dylibs are not signed with the app's team. Rebuild so `cef-embed` re-signs them; check `codesign --verify --deep --strict MyApp.app`. |
| App is "damaged" after editing the bundle | The helpers changed after Xcode sealed the app. `cef-embed` touches the app's `Info.plist` so Xcode re-signs; a clean build fixes a stale seal. |
| Password prompt for "Chromium Safe Storage" | `useSystemKeychain` is on and another CEF app owns that keychain item. |
| Renderer dies on a `srcdoc` iframe | Known CEF 154 issue in pages loaded from `data:` URLs, including `loadHTML(_:)`. |
| `evaluateJavaScript` never returns | The script's promise never settles. Evaluations fail on navigation, close or renderer exit, but not on a promise that just never resolves. |
