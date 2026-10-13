# CEFWebView

A SwiftUI view backed by Chromium, through the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef) (CEF). macOS 15+, Apple silicon.

A work in progress: see [docs/REUSABLE_PACKAGE.md](docs/REUSABLE_PACKAGE.md) for what is done and what is left.

## Installing

1. **Add the package.** In Xcode, File → Add Package Dependencies, enter `https://github.com/brennanMKE/CEFWebView`, and add the `CEFWebView` library to your app target. Xcode downloads the CEF framework (about 145 MB) and embeds and signs it in your app.

2. **Add one Run Script phase** to the app target, after "Link Binary With Libraries":

   ```sh
   "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/CEFWebView/Scripts/cef-embed"
   ```

   Uncheck "Based on dependency analysis" (the script decides itself what needs rebuilding). It builds the CEF helper and installs `<App> Helper.app`, `<App> Helper (GPU).app`, `<App> Helper (Renderer).app` and `<App> Helper (Alerts).app` in `Contents/Frameworks`, named after your app and signed with your app's identity.

3. **Build settings** on the app target:
   - `ENABLE_USER_SCRIPT_SANDBOXING = NO`, because the script writes into the app bundle.
   - App Sandbox off. CEF's sandbox is not supported yet.

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
   | `gpuEnabled` | `true` | `false` renders in software. |
   | `verboseLogging` | `false` | Chromium logs warnings and errors to `chrome_debug.log` in the profile directory. |
   | `useSystemKeychain` | `false` | Encrypt cookies with a login-keychain key. Chromium names the item "Chromium Safe Storage" in every CEF app, so macOS asks for the login password when another app created it. Ignored for ad-hoc signed builds. |
   | `profileDirectory` | `nil` | Cookies, local storage and cache. `nil` uses `~/Library/Application Support/<bundle id>/CEF`. |

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

## Developing

The demo app is `WebView/WebView.xcodeproj`, which uses this package from the local checkout.

`Scripts/update_cef.sh` downloads the pinned CEF distribution, vendors its C++ wrapper into `Sources/CEFDLLWrapper`, and builds `Frameworks/ChromiumEmbeddedFramework.xcframework`. When that folder exists, `Package.swift` uses it instead of the release download. To move to a new CEF version, change `CEF_VERSION` in the script, run it, then follow the release steps it prints.

## License

MIT License - See LICENSE file for details. CEF is BSD-licensed; see `Sources/CEFDLLWrapper/LICENSE.txt`.
