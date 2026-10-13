# Running the tests in a Tart VM

The demo app's tests open windows, take keyboard focus, activate the app and send mouse events, and
the UI test targets load `XCTAutomationSupport` into running GUI apps. None of that may happen on the
host, which is a working Mac. They run only inside a disposable macOS guest that
[Tart](https://tart.run) boots headless, then deletes.

| Test | Where it runs |
| --- | --- |
| `swift test` (package unit tests, no windows) | Host |
| `WebViewTests` (integration tests that drive a real browser) | **Tart guest only** |
| `WebViewUITests` (XCUITest) | **Tart guest only** |

Background for the host setup (golden image, permissions, memory, why a VM is safe for the host) is
in `~/Developer/Homelab/cameron/tart-ui-test-vm.md`. This doc covers what is specific to CEFWebView.

## Run

```sh
Scripts/run-tests-vm.sh
```

That tests the working tree, uncommitted changes included, with every test in the `WebView` scheme.
Results land in `build/vm-tests/<run-id>/`. The script exits with `xcodebuild`'s status.

| File | Contents |
| --- | --- |
| `xcodebuild.log` | Build and test output |
| `Tests.xcresult` | Result bundle, with failure messages |
| `app.log` | The guest's system log for the app and helpers: `CEFWrapper`'s `NSLog` lines, including renderer crashes (`OnRenderProcessTerminated`) |
| `chrome_debug.log` | Chromium's own warnings and errors |
| `crashes/` | Crash reports (`.ips`) for the app and its helpers, such as a renderer that died |

```sh
Scripts/run-tests-vm.sh --ref HEAD                 # a commit instead of the working tree
Scripts/run-tests-vm.sh -- -only-testing:WebViewTests
Scripts/run-tests-vm.sh -- "-only-testing:WebViewTests/CEFWebViewAPITests/findsTextInThePage()"
```

Anything after `--` is passed to `xcodebuild test`. Swift Testing identifiers need the trailing `()`;
without it the filter matches nothing and the run "succeeds" with zero tests.

To read failures from the result bundle:

```sh
xcrun xcresulttool get test-results tests --path build/vm-tests/<run-id>/Tests.xcresult
```

A run takes about 3 to 5 minutes: boot ~15 s, then a clean build of the demo app, the CEF helper and
the vendored C++ wrapper, then the tests.

## What the script does

1. **Preflight.** Resolves the host's one shared golden image with `tart-golden require --xcode 27.0`,
   never a hardcoded name. Checks 20 GiB of free disk. If the host is short of memory, asks for it
   through the memory-signal protocol. Sweeps clones a killed earlier run left behind, matching only
   its own `cefwebview-uitest-<date>-<time>-<pid>` names, which can never match a golden.
2. **Snapshot.** Writes the working tree to a tree object through a throwaway index (the real index
   is untouched), or uses `--ref`, and `git archive`s it to one tar file. Adds the local
   `Frameworks/ChromiumEmbeddedFramework.xcframework` (gitignored) to the same tar, so the guest does
   not download the 145 MB release zip. Without a local copy, `Package.swift` downloads it.
3. **Slot.** Takes a `tart-lease` slot: the host runs at most two guests across all projects.
4. **Boot.** Clones the golden, runs it with `--no-graphics --no-audio`, and shares the export
   directory read-only.
5. **Test.** In the guest, extracts the tar into `~/src` and runs `xcodebuild test` with ad-hoc
   signing (below), piping through `tee` with `pipefail` set *inside the guest shell*. Without it the
   status is `tee`'s, which is always 0.
6. **Results.** Saves the app's log and Chromium's log, then streams `~/results` back with
   `tart exec … tar`, not through the read-only share.
7. **Cleanup.** An `EXIT` trap releases the lease and the memory request, stops and deletes the clone,
   and removes the export.

## CEFWebView specifics

**One tar file, not a shared folder.** Tart's virtio-fs shares do not pass symlinks through. The CEF
framework is a versioned bundle (`Versions/Current`, top-level links to `Versions/A`); copied through
the share, its links break and it can no longer be signed. A single tar file crosses intact.

**Ad-hoc signing.** The guest has no signing identity, so the build passes `CODE_SIGN_STYLE=Manual
CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO`. The hardened runtime has to go:
its library validation rejects ad-hoc code from another signature, which would stop the helpers
loading the framework and `libcef_sandbox.dylib`. `Scripts/cef-embed` sees the `-` identity and signs
the helpers ad hoc too. Chromium's sandbox still runs.

**No prompts.** Ad-hoc builds always use the mock keychain (`CEFConfiguration.useSystemKeychain` is
ignored for them), so the "Chromium Safe Storage" password dialog cannot appear. Notification banners
in the guest are harmless: nobody sees them and the guest is deleted.

**Network.** The guest uses Tart's default NAT and can reach the internet. Tests use `data:` URLs
and `https://cefwebview.invalid/…` for navigations the policy cancels, so they do not depend on the
network, except `reportsLoadErrors`, which needs DNS to fail fast.

**Display.** The golden's display is 1024×768. Test windows are 800×600 and ordered front, because
CEF only selects find matches in a visible window.

**No synthetic mouse events.** A click needs the app to be active, and macOS can refuse activation,
especially in a headless guest. Tests that need a user gesture use `runScriptAsUserGesture(_:)`
instead, which runs the script through DevTools' `Runtime.evaluate` with `userGesture: true`.

## Writing tests that run here

The integration tests are in `WebView/WebViewTests/WebViewTests.swift` and run inside `WebView.app`
(the test host), where `AppDelegate` has already initialized CEF. The `Browser` harness opens one
`CEFWebView` in its own window:

- `Browser(html:title:)` loads the HTML as a `data:` URL and waits until the page title matches, so a
  test starts on a loaded page.
- `waitUntil(_:timeout:_:)` polls a condition while the main run loop, and with it CEF's message pump,
  keeps running. Never block the main thread: CEF runs on it.
- `run(_:)` evaluates a script for its side effects.
- `state.runScriptAsUserGesture(_:)` (imported with `@_spi(Testing) import CEFWebView`) runs a script
  as if the user had clicked. Pop-ups need it; Chromium's pop-up blocker drops `window.open` called
  from ordinary script.
- `focus()` makes the test window key, for behavior that needs focus.
- The suite is `.serialized` with a one-minute `.timeLimit`, so a hang fails one test instead of
  stalling the run.

## When something goes wrong

| Symptom | Cause |
| --- | --- |
| `tart-golden: requirements not met` | The golden's Xcode differs from `--xcode 27.0` in the script. Update the script when the host moves to a new Xcode and the golden has been rebuilt. |
| Guest not reachable within 120 s | Check the host's `login.keychain` is unlocked: Virtualization.framework will not boot a macOS guest otherwise (`Code=-9`, "Failed to create new HostKey"). |
| Run waits before cloning | Another project holds both Tart slots; `tart-lease status` shows who. |
| `TEST SUCCEEDED` with no tests | An `-only-testing:` filter without the trailing `()` on a Swift Testing name. |
| A test exceeds its time limit | Usually an `await` the page never answers. `evaluateJavaScript` fails when the page navigates, crashes or closes, but not when a script simply never settles. |
| Clone left in `tart list` | The script was SIGKILLed; the next run sweeps it. |
