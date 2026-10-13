import Cocoa
import CEFWrapper
import os.log

nonisolated let cefLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "CEFApplication")

// MARK: - Configuration

/// Process-wide settings for `CEFApplication.initialize(_:)`. The defaults suit a shipping app.
public struct CEFConfiguration: Sendable {
    /// Hardware-accelerated rendering. Turn off to render in software.
    public var gpuEnabled: Bool

    /// Verbose Chromium logging. Off logs warnings and errors only, to `chrome_debug.log` in
    /// `profileDirectory`.
    public var verboseLogging: Bool

    /// Encrypt cookies with a key in the login keychain. Off by default: Chromium names the item
    /// "Chromium Safe Storage" in every CEF app, so macOS asks for the login password whenever an app
    /// that did not create it reads it. Ignored for ad-hoc signed builds. When off, cookies are stored
    /// unencrypted in `profileDirectory`.
    public var useSystemKeychain: Bool

    /// Where the browser profile (cookies, local storage, cache) is stored. `nil` uses
    /// `~/Library/Application Support/<bundle id>/CEF`.
    public var profileDirectory: URL?

    public init(
        gpuEnabled: Bool = true,
        verboseLogging: Bool = false,
        useSystemKeychain: Bool = false,
        profileDirectory: URL? = nil
    ) {
        self.gpuEnabled = gpuEnabled
        self.verboseLogging = verboseLogging
        self.useSystemKeychain = useSystemKeychain
        self.profileDirectory = profileDirectory
    }
}

// MARK: - CEF Application Lifecycle Manager

/// Process-wide CEF lifecycle: initialization, shutdown, and helper processes shared by all browsers.
@MainActor
public final class CEFApplication {
    public static let shared = CEFApplication()

    private var isInitialized = false

    /// Every live `CEFBrowserHost`, so process-wide helper status reaches each view's state.
    private let browserHosts = NSHashTable<CEFBrowserHost>.weakObjects()

    /// Helper processes that have launched. GPU/network/storage typically spawn during
    /// `CefInitialize`, before any browser exists, so they are recorded here and applied on attach.
    private var spawnedHelpers: Set<String> = []

    nonisolated(unsafe) private var spawnedObserver: NSObjectProtocol?

    private init() {
        spawnedObserver = NotificationCenter.default.addObserver(
            forName: .CEFHelperSpawned,
            object: nil,
            queue: .main
        ) { notification in
            guard let helperType = notification.userInfo?["type"] as? String else {
                cefLogger.warning("CEFHelperSpawned missing type: \(String(describing: notification.userInfo))")
                return
            }
            MainActor.assumeIsolated {
                CEFApplication.shared.recordHelperSpawned(helperType)
            }
        }
    }

    deinit {
        if let observer = spawnedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Handle CEF subprocess roles at the very start of the app, before any other initialization.
    /// If this process is a CEF subprocess (renderer, GPU, utility, network), this method will
    /// call exit() — it does not return. If this is the main browser process, returns normally.
    /// Must be called from the main thread before SwiftUI initializes.
    public nonisolated static func handleSubprocessIfNeeded() {
        let exitCode = CEFWrapper.executeSubprocess(withArgc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        if exitCode >= 0 {
            // This is a subprocess; exit with the exit code returned by CefExecuteProcess
            exit(exitCode)
        }
        // exitCode < 0 means main browser process — continue with normal app startup
    }

    /// Initialize CEF framework. Call once at app startup.
    public func initialize(_ configuration: CEFConfiguration = CEFConfiguration()) throws {
        guard !isInitialized else {
            cefLogger.debug("CEF already initialized, skipping")
            return
        }

        let options = CEFInitializationOptions()
        options.gpuEnabled = configuration.gpuEnabled
        options.verboseLogging = configuration.verboseLogging
        options.useSystemKeychain = configuration.useSystemKeychain
        options.profileDirectory = configuration.profileDirectory?.path

        // Swift bridges initializeCEFWithOptions:error: as a throwing method
        do {
            try CEFWrapper.initializeCEF(with: options)
        } catch {
            let error = error as NSError
            let errorDesc = error.localizedDescription
            cefLogger.error("CEF INITIALIZATION FAILED: \(errorDesc, privacy: .public) (code: \(error.code))")
            throw CEFError.initializationFailed(reason: errorDesc)
        }

        cefLogger.info("CEF Initialized Successfully")
        isInitialized = true
    }

    /// Number of browsers created and not yet fully closed.
    public var openBrowserCount: Int {
        CEFWrapper.openBrowserCount()
    }

    func register(_ host: CEFBrowserHost) {
        browserHosts.add(host)
        if let state = host.state {
            applySpawnedHelpers(to: state)
        }
    }

    func unregister(_ host: CEFBrowserHost) {
        browserHosts.remove(host)
    }

    func recordHelperSpawned(_ type: String) {
        let lowerType = type.lowercased()
        guard ["gpu", "network", "storage", "renderer"].contains(lowerType) else {
            cefLogger.warning("Unknown helper type from CEF: \(type)")
            return
        }
        spawnedHelpers.insert(lowerType)
        for host in browserHosts.allObjects {
            if let state = host.state {
                applySpawnedHelpers(to: state)
            }
        }
    }

    private func applySpawnedHelpers(to state: CEFWebViewState) {
        if spawnedHelpers.contains("gpu"), !state.gpuHelperSpawned { state.gpuHelperSpawned = true }
        if spawnedHelpers.contains("network"), !state.networkHelperSpawned { state.networkHelperSpawned = true }
        if spawnedHelpers.contains("storage"), !state.storageHelperSpawned { state.storageHelperSpawned = true }
        if spawnedHelpers.contains("renderer"), !state.rendererHelperSpawned { state.rendererHelperSpawned = true }
    }

    /// Close every open browser and shut CEF down. Call once, at app termination.
    public func shutdown() {
        guard isInitialized else { return }
        CEFWrapper.shutdown()
        isInitialized = false
    }
}

// MARK: - CEF Browser Host Wrapper

/// Owns one CEF browser and pushes its events into a `CEFWebViewState`.
@MainActor
public final class CEFBrowserHost: NSObject {
    private let handle: CEFBrowserHandle
    /// Observable SwiftUI state for this browser only.
    internal weak var state: CEFWebViewState?

    /// The native macOS view for CEF rendering.
    public var nativeView: NSView? { handle.browserView }

    /// Create a browser as a child of `parentView` with an initial URL.
    public init(parentView: NSView, url: URL, state: CEFWebViewState? = nil) throws {
        guard let handle = CEFBrowserHandle(parentView: parentView, url: url.absoluteString, delegate: nil) else {
            let errorMsg = "CEF could not create a browser. Likely causes: helper executable crash, " +
                           "dyld library loading failure, JIT entitlements missing, or invalid code signatures."
            cefLogger.error("BROWSER CREATION FAILED: \(errorMsg, privacy: .public)")
            throw CEFError.browserCreationFailed(reason: errorMsg)
        }
        self.handle = handle
        self.state = state
        super.init()
        handle.delegate = self
        CEFApplication.shared.register(self)
    }

    /// Load a URL in the browser.
    func loadURL(_ url: URL) {
        guard handle.isOpen else { return }
        state?.clearLoadError()
        cefLogger.info("loadURL: \(url.absoluteString)")
        handle.loadURL(url.absoluteString)
    }

    func reload() {
        handle.reload()
    }

    func goBack() {
        handle.goBack()
    }

    func goForward() {
        handle.goForward()
    }

    func notifyGeometryChanged() {
        handle.notifyGeometryChanged()
    }

    /// Start closing the browser. CEF finishes asynchronously; `CEFApplication.shutdown()` waits for it.
    func close() {
        handle.close()
        CEFApplication.shared.unregister(self)
    }
}

extension CEFBrowserHost: CEFBrowserHandleDelegate {
    public func browserHandle(_ handle: CEFBrowserHandle, loadingStateChanged isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let state else { return }
        if state.isLoading != isLoading { state.isLoading = isLoading }
        if state.canGoBack != canGoBack { state.canGoBack = canGoBack }
        if state.canGoForward != canGoForward { state.canGoForward = canGoForward }
    }

    public func browserHandle(_ handle: CEFBrowserHandle, progressChanged progress: Double) {
        state?.estimatedProgress = progress
    }

    public func browserHandle(_ handle: CEFBrowserHandle, titleChanged title: String?) {
        state?.title = title
    }

    public func browserHandle(_ handle: CEFBrowserHandle, addressChanged url: String) {
        guard let state, let url = URL(string: url), state.currentURL != url else { return }
        state.currentURL = url
    }

    public func browserHandle(_ handle: CEFBrowserHandle, mainFrameLoadFailedWithCode errorCode: Int, errorText: String?, failedURL: String?) {
        guard let state else { return }
        state.rendererHelperFailed = true
        state.lastMainFrameLoadErrorCode = errorCode
        state.lastMainFrameLoadErrorText = errorText
        state.isLoading = false
    }

    public func browserHandle(_ handle: CEFBrowserHandle, renderProcessTerminatedWithStatus status: Int) {
        guard let state else { return }
        state.rendererHelperFailed = true
        state.rendererHelperSpawned = false
        state.lastMainFrameLoadErrorCode = nil
        state.lastMainFrameLoadErrorText = nil
        state.isLoading = false
    }

    public func browserHandleDidClose(_ handle: CEFBrowserHandle) {
        cefLogger.info("Browser closed (open browsers: \(CEFWrapper.openBrowserCount()))")
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
