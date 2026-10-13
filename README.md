# CEFWebView

A SwiftUI view backed by Chromium, through the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef) (CEF). macOS 15+, Apple silicon.

Status and roadmap: [docs/REUSABLE_PACKAGE.md](docs/REUSABLE_PACKAGE.md). How it works inside:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installing

1. **Add the package.** In Xcode, File → Add Package Dependencies, enter `https://github.com/brennanMKE/CEFWebView`, and add the `CEFWebView` library to your app target. Xcode downloads the CEF framework (about 145 MB) and embeds and signs it in your app.

2. **Add one Run Script phase** to the app target, after "Link Binary With Libraries":

   ```sh
   "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/CEFWebView/Scripts/cef-embed"
   ```

   Uncheck "Based on dependency analysis" (the script decides itself what needs rebuilding). It builds the CEF helper and installs `<App> Helper.app`, `<App> Helper (GPU).app`, `<App> Helper (Renderer).app` and `<App> Helper (Alerts).app` in `Contents/Frameworks`, named after your app and signed with your app's identity.

3. **Build settings** on the app target:
   - `ENABLE_USER_SCRIPT_SANDBOXING = NO`, because the script writes into the app bundle.
   - App Sandbox off: CEF does not support it. Chromium's own sandbox still isolates the helper
     processes.
   - Hardened runtime on (for notarization), with these entitlements in the app's entitlements file.
     V8 compiles JavaScript to machine code; without them pages stay blank. The helpers get the same
     from `cef-embed`.

     ```xml
     <key>com.apple.security.cs.allow-jit</key>
     <true/>
     <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
     <true/>
     ```

4. **Handle CEF subprocesses first.** The helpers run CEF's subprocess code, but the app must also return early when it is launched in a subprocess role, and shut CEF down on quit:

   ```swift
   import SwiftUI
   import CEFWebView

   @main
   struct MyApp: App {
       @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

       init() {
           CEFApplication.handleSubprocessIfNeeded()
       }

       var body: some Scene {
           WindowGroup { ContentView() }
       }
   }

   final class AppDelegate: NSObject, NSApplicationDelegate {
       func applicationDidFinishLaunching(_ notification: Notification) {
           try? CEFApplication.shared.initialize()
       }

       func applicationWillTerminate(_ notification: Notification) {
           CEFApplication.shared.shutdown()
       }
   }
   ```

   `initialize` takes an optional `CEFConfiguration`. The defaults suit a shipping app:

   | Setting | Default | |
   | --- | --- | --- |
   | `sandboxEnabled` | `true` | Runs helpers in Chromium's sandbox, so a compromised renderer cannot reach files, the network or other processes directly. Turn off only for content you control. |
   | `gpuEnabled` | `true` | `false` renders in software. |
   | `verboseLogging` | `false` | Chromium logs warnings and errors to `chrome_debug.log` in the profile directory. |
   | `useSystemKeychain` | `false` | Encrypt cookies with a login-keychain key. Chromium names the item "Chromium Safe Storage" in every CEF app, so macOS asks for the login password when another app created it. Ignored for ad-hoc signed builds. |
   | `systemNotificationsEnabled` | `false` | Let pages show notifications through Notification Center. Off, pages see notification permission denied and Chromium does not register the app with Notification Center. |
   | `profileDirectory` | `nil` | Cookies, local storage and cache. `nil` uses `~/Library/Application Support/<bundle id>/CEF`. |
   | `userAgent` | `nil` | Replaces Chrome's user agent. |

   ```swift
   try CEFApplication.shared.initialize(CEFConfiguration(verboseLogging: true))
   ```

5. **Use the view:**

   ```swift
   struct ContentView: View {
       @State private var url: URL? = URL(string: "https://example.com")
       @State private var state = CEFWebViewState()

       var body: some View {
           CEFWebView(url: $url, state: $state)
               .navigationTitle(state.title ?? "")
       }
   }
   ```

## Using the API

`CEFWebViewState` is both the view's observable state and the way to control it:

```swift
// Run JavaScript; promises are awaited. Results arrive JSON-decoded.
let count = try await state.evaluateJavaScript("document.links.length") as? Int

// Messages from the page: window.cefWebView.postMessage("saved", {id: 42})
state.setMessageHandler("saved") { message in
    print(message.body ?? "nil", message.isMainFrame)
}

// Decide navigations, in any frame, before they start.
state.navigationPolicy = { action in
    action.url?.scheme == "mailto" ? .cancel : .allow
}

// Pop-ups load in place by default. To open your own window instead:
state.newWindowPolicy = { action in
    if let url = action.url { openWindow(value: url) }
    return .block
}

// Downloads go to ~/Downloads unless a policy picks a destination (or nil to cancel).
state.downloadPolicy = { request in downloadsFolder.appendingPathComponent(request.suggestedFilename) }

state.find("search text")          // findResult: match count and active match
state.pageZoom = 1.25
state.loadHTML("<h1>Hello</h1>")
```

Also: `lastError` (main-frame load failures), `processStatus`, `downloads`, `stopLoading()`,
`CEFApplication.shared.deleteAllCookies()`, and `CEFConfiguration.userAgent`.

**Known issue (CEF 154):** a `srcdoc` iframe inside a page loaded from a `data:` URL, including
`loadHTML(_:)`, crashes the renderer. `srcdoc` in http(s) pages is fine.

## Shipping

Archive with a Developer ID identity and notarize as for any app. `cef-embed` signs the helpers and
the framework's dylibs with the app's identity, so the archive notarizes as is. The demo app's
`Scripts/notarize.sh` shows the whole flow with Xcode's signed-in account: archive, upload, wait,
staple, check with `spctl`.

## Developing

The demo app is `WebView/WebView.xcodeproj`, which uses this package from the local checkout.

Tests: `swift test` runs the package's unit tests on the host. The demo's integration and UI tests open
windows, so they run only in a disposable Tart VM: `Scripts/run-tests-vm.sh`. See
[docs/TESTING_IN_TART.md](docs/TESTING_IN_TART.md).

CI (`.github/workflows/ci.yml`) runs the unit tests and the demo's tests on every push and pull
request, on a disposable GitHub runner.

`Scripts/update_cef.sh` downloads the pinned CEF distribution, vendors its C++ wrapper into `Sources/CEFDLLWrapper`, and builds `Frameworks/ChromiumEmbeddedFramework.xcframework`. When that folder exists, `Package.swift` uses it instead of the release download. Moving to a new CEF version and publishing a release: [docs/UPDATING_CEF.md](docs/UPDATING_CEF.md).

## License

MIT License - See LICENSE file for details. CEF is BSD-licensed; see `Sources/CEFDLLWrapper/LICENSE.txt`.
