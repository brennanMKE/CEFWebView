import Cocoa
import CEFWrapper
import os.log

nonisolated(unsafe) let cefLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "CEFApplication")

// MARK: - CEF Application Lifecycle Manager

/// Manages CEF initialization and shutdown on the main thread.
@MainActor
public final class CEFApplication {
    public static let shared = CEFApplication()

    private var isInitialized = false
    private var messagePumpTimer: Timer?
    weak var activeBrowserHost: CEFBrowserHost?

    /// Handle CEF subprocess roles at the very start of the app, before any other initialization.
    /// If this process is a CEF subprocess (renderer, GPU, utility, network), this method will
    /// call exit() — it does not return. If this is the main browser process, returns normally.
    /// Must be called from the main thread before SwiftUI initializes.
    public nonisolated static func handleSubprocessIfNeeded() {
        cefLogger.debug("handleSubprocessIfNeeded called")

        let exitCode = CEFWrapper.executeSubprocess(withArgc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        cefLogger.debug("CefExecuteProcess returned exitCode=\(exitCode)")

        if exitCode >= 0 {
            // This is a subprocess; exit with the exit code returned by CefExecuteProcess
            cefLogger.debug("This is a subprocess, exiting with code \(exitCode)")
            exit(exitCode)
        }
        // exitCode < 0 means main browser process — continue with normal app startup
        cefLogger.debug("This is the main browser process, continuing startup")
    }

    /// Initialize CEF framework. Call once at app startup.
    public func initialize() throws {
        guard !isInitialized else {
            print("✓ CEF already initialized, skipping")
            return
        }

        // Swift bridges initializeCEFWithError: as a throwing method
        do {
            try CEFWrapper.initializeCEF()
        } catch let error as NSError {
            let errorDesc = error.localizedDescription
            print("❌ ========================================")
            print("❌ CEF INITIALIZATION FAILED")
            print("❌ ========================================")
            print("❌ Error: \(errorDesc)")
            print("❌ Error Code: \(error.code)")
            print("❌ ========================================")
            throw CEFError.initializationFailed(reason: errorDesc)
        } catch {
            print("❌ CEF initialization failed with unknown error: \(error)")
            throw CEFError.initializationFailed(reason: error.localizedDescription)
        }

        print("✅ ========================================")
        print("✅ CEF Initialized Successfully")
        print("✅ ========================================")
        isInitialized = true
        startMessagePump()
        print("✅ CEF message pump started")
    }


    /// Start the CEF message pump on the main thread.
    private func startMessagePump() {
        messagePumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processMessages()
            }
        }
        RunLoop.main.add(messagePumpTimer!, forMode: .common)
    }

    /// Process pending CEF messages (called from timer on main thread).
    private func processMessages() {
        CEFWrapper.doMessageLoopWork()
        activeBrowserHost?.updateState()
    }

    /// Shutdown CEF gracefully. Should be called on app termination.
    public func shutdown() {
        messagePumpTimer?.invalidate()
        messagePumpTimer = nil
        CEFWrapper.shutdown()
        isInitialized = false
    }
}

// MARK: - CEF Browser Host Wrapper

/// Wraps a CEF browser instance on the main thread.
@MainActor
public final class CEFBrowserHost {
    private var isAlive = true
    private weak var state: CEFWebViewState?

    /// The native macOS view for CEF rendering.
    public let nativeView: NSView?

    /// Create a browser instance with an initial URL.
    public init(parentView: NSView, url: URL, state: CEFWebViewState? = nil) throws {
        print("🔧 Creating CEF browser in parentView: \(parentView.frame), url: \(url.absoluteString)")

        guard let browserView = CEFWrapper.createBrowser(in: parentView, url: url.absoluteString) else {
            let errorMsg = "CEFWrapper.createBrowser returned nil. This indicates the browser subprocess failed to initialize. " +
                          "Likely causes: helper executable crash, dyld library loading failure, JIT entitlements missing, " +
                          "or invalid code signatures. Check system logs and CEF debug log at ~/Library/Caches/com.chromium.webview/debug.log"
            print("❌ ========================================")
            print("❌ BROWSER CREATION FAILED")
            print("❌ ========================================")
            print("❌ \(errorMsg)")
            print("❌ ========================================")
            throw CEFError.browserCreationFailed(reason: errorMsg)
        }

        print("✅ ========================================")
        print("✅ CEF Browser View Created Successfully")
        print("✅ View: \(browserView)")
        print("✅ ========================================")
        self.nativeView = browserView
        self.state = state
    }

    /// Load a URL in the browser.
    func loadURL(_ url: URL) {
        guard isAlive else { return }
        print("🌐 loadURL: \(url.absoluteString)")
        CEFWrapper.loadURL(url.absoluteString)
        updateState()
    }

    func reload() {
        guard isAlive else { return }
        CEFWrapper.reloadBrowser()
    }

    func goBack() {
        guard isAlive else { return }
        CEFWrapper.goBack()
        updateState()
    }

    func goForward() {
        guard isAlive else { return }
        CEFWrapper.goForward()
        updateState()
    }

    /// Update state from CEF's current values.
    func updateState() {
        state?.isLoading = CEFWrapper.isLoading()
        state?.canGoBack = CEFWrapper.canGoBack()
        state?.canGoForward = CEFWrapper.canGoForward()
        state?.title = CEFWrapper.currentTitle()
        if let urlString = CEFWrapper.currentURL(),
           let url = URL(string: urlString) {
            state?.currentURL = url
        }
    }

    func close() {
        guard isAlive else { return }
        isAlive = false
        CEFWrapper.closeBrowser()
    }
}

// MARK: - Error Types

enum CEFError: Error {
    case resourcesNotFound
    case initializationFailed(reason: String)
    case browserCreationFailed(reason: String)

    var localizedDescription: String {
        switch self {
        case .resourcesNotFound:
            return "CEF resources not found"
        case .initializationFailed(let reason):
            return "CEF initialization failed: \(reason)"
        case .browserCreationFailed(let reason):
            return "Browser creation failed: \(reason)"
        }
    }
}
