import Cocoa
import CEFWrapper

// MARK: - CEF Application Lifecycle Manager

/// Manages CEF initialization and shutdown on the main thread.
@MainActor
public final class CEFApplication {
    public static let shared = CEFApplication()

    private var isInitialized = false
    private var messagePumpTimer: Timer?
    weak var activeBrowserHost: CEFBrowserHost?

    /// Initialize CEF framework. Call once at app startup.
    public func initialize() throws {
        guard !isInitialized else {
            print("✓ CEF already initialized, skipping")
            return
        }

        // Swift bridges initializeCEFWithError: as a throwing method
        do {
            try CEFWrapper.initializeCEF()
        } catch {
            print("❌ CEF initialization failed: \(error.localizedDescription)")
            throw CEFError.initializationFailed
        }

        print("✓ CEF initialized")
        isInitialized = true
        startMessagePump()
        print("✓ CEF message pump started")
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
            print("❌ CEFWrapper.createBrowser returned nil")
            throw CEFError.browserCreationFailed
        }

        print("✓ CEF browser view created: \(browserView)")
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
    case initializationFailed
    case browserCreationFailed
}
