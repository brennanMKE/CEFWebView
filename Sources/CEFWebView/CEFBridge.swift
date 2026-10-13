import Cocoa
import CEFWrapper
import os.log

nonisolated let cefLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "CEFApplication")

// MARK: - Configuration

/// Process-wide settings for `CEFApplication.initialize(_:)`. The defaults suit a shipping app.
nonisolated public struct CEFConfiguration: Sendable {
    /// Run helper processes in Chromium's sandbox, so a compromised renderer cannot reach the file
    /// system, network or other processes directly. Turn off only for content you control.
    public var sandboxEnabled: Bool

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

    /// Let pages show notifications through macOS Notification Center. Off by default: pages see
    /// notification permission denied, and Chromium does not start its notification service, which
    /// would register the app and its Alerts helper with Notification Center and make macOS show
    /// "Notifications may include alerts…" banners.
    public var systemNotificationsEnabled: Bool

    /// Where the browser profile (cookies, local storage, cache) is stored. `nil` uses
    /// `~/Library/Application Support/<bundle id>/CEF`.
    public var profileDirectory: URL?

    /// User-Agent header and `navigator.userAgent`. `nil` uses Chrome's.
    public var userAgent: String?

    public init(
        sandboxEnabled: Bool = true,
        gpuEnabled: Bool = true,
        verboseLogging: Bool = false,
        useSystemKeychain: Bool = false,
        systemNotificationsEnabled: Bool = false,
        profileDirectory: URL? = nil,
        userAgent: String? = nil
    ) {
        self.sandboxEnabled = sandboxEnabled
        self.gpuEnabled = gpuEnabled
        self.verboseLogging = verboseLogging
        self.useSystemKeychain = useSystemKeychain
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.profileDirectory = profileDirectory
        self.userAgent = userAgent
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
    private var launchedProcesses: Set<CEFProcessType> = []

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
        options.sandboxEnabled = configuration.sandboxEnabled
        options.gpuEnabled = configuration.gpuEnabled
        options.verboseLogging = configuration.verboseLogging
        options.useSystemKeychain = configuration.useSystemKeychain
        options.systemNotificationsEnabled = configuration.systemNotificationsEnabled
        options.profileDirectory = configuration.profileDirectory?.path
        options.userAgent = configuration.userAgent

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
        host.state?.processStatus.launched = launchedProcesses
    }

    func unregister(_ host: CEFBrowserHost) {
        browserHosts.remove(host)
    }

    func recordHelperSpawned(_ type: String) {
        guard let process = CEFProcessType(rawValue: type.lowercased()) else {
            cefLogger.warning("Unknown helper type from CEF: \(type)")
            return
        }
        guard launchedProcesses.insert(process).inserted else { return }
        for host in browserHosts.allObjects {
            host.state?.processStatus.launched = launchedProcesses
        }
    }

    /// Delete every cookie in the profile. Returns how many were deleted.
    @discardableResult
    public func deleteAllCookies() async -> Int {
        await withCheckedContinuation { continuation in
            CEFWrapper.deleteAllCookies { continuation.resume(returning: $0) }
        }
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
        state?.clearLoadError()
        handle.reload()
    }

    func stopLoading() {
        handle.stopLoading()
    }

    func goBack() {
        handle.goBack()
    }

    func goForward() {
        handle.goForward()
    }

    /// JSON text of the result, or `nil` for `undefined`.
    func evaluateJavaScript(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            handle.evaluateJavaScript(script) { json, errorMessage, pageUnavailable in
                if let errorMessage {
                    continuation.resume(throwing: pageUnavailable
                        ? CEFJavaScriptError.pageUnavailable(errorMessage)
                        : CEFJavaScriptError.exception(errorMessage))
                } else {
                    continuation.resume(returning: json)
                }
            }
        }
    }

    func runScriptAsUserGesture(_ script: String) {
        handle.runScript(asUserGesture: script)
    }

    var zoomLevel: Double {
        get { handle.zoomLevel }
        set { handle.zoomLevel = newValue }
    }

    func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        handle.find(text, forward: forward, matchCase: matchCase, findNext: findNext)
    }

    func stopFinding() {
        handle.stopFinding(true)
    }

    func cancelDownload(_ id: UInt32) {
        handle.cancelDownload(id)
    }

    func notifyGeometryChanged() {
        handle.notifyGeometryChanged()
    }

    /// Start closing the browser. CEF finishes asynchronously; `CEFApplication.shutdown()` waits for it.
    func close() {
        handle.close()
        CEFApplication.shared.unregister(self)
    }

    /// ~/Downloads/<name>, numbered if that file exists.
    private static func defaultDownloadDestination(for suggestedName: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedName.isEmpty ? "download" : suggestedName
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
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
        state.lastError = CEFLoadError(code: errorCode, description: errorText ?? "", url: failedURL.flatMap(URL.init(string:)))
        state.isLoading = false
    }

    public func browserHandle(_ handle: CEFBrowserHandle, renderProcessTerminatedWithStatus status: Int) {
        guard let state else { return }
        state.processStatus.rendererTerminated = true
        state.isLoading = false
    }

    public func browserHandleDidClose(_ handle: CEFBrowserHandle) {
        cefLogger.info("Browser closed (open browsers: \(CEFWrapper.openBrowserCount()))")
    }

    public func browserHandle(_ handle: CEFBrowserHandle, shouldNavigateToURL url: String, isMainFrame: Bool, isUserGesture: Bool, isRedirect: Bool) -> Bool {
        guard let policy = state?.navigationPolicy else { return true }
        let action = CEFNavigationAction(urlString: url, isMainFrame: isMainFrame, isUserGesture: isUserGesture, isRedirect: isRedirect)
        return policy(action) == .allow
    }

    public func browserHandle(_ handle: CEFBrowserHandle, decidePopupForURL url: String, isUserGesture: Bool) -> CEFPopupDecision {
        guard let policy = state?.newWindowPolicy else { return .loadInPlace }
        switch policy(CEFNewWindowAction(urlString: url, isUserGesture: isUserGesture)) {
        case .loadInPlace: return .loadInPlace
        case .block: return .block
        }
    }

    public func browserHandle(_ handle: CEFBrowserHandle, didReceiveScriptMessage name: String, bodyJSON: String?, isMainFrame: Bool) {
        state?.receiveScriptMessage(name: name, bodyJSON: bodyJSON, isMainFrame: isMainFrame)
    }

    public func browserHandle(_ handle: CEFBrowserHandle, findResultCount count: Int, activeMatch: Int, finalUpdate: Bool) {
        state?.findResult = CEFFindResult(matchCount: count, activeMatch: activeMatch)
    }

    public func browserHandle(_ handle: CEFBrowserHandle, destinationForDownload downloadID: UInt32, url: String, suggestedName: String, mimeType: String) -> String? {
        let request = CEFDownloadRequest(url: URL(string: url), suggestedFilename: suggestedName, mimeType: mimeType)
        let destination: URL?
        if let policy = state?.downloadPolicy {
            destination = policy(request)
        } else {
            destination = Self.defaultDownloadDestination(for: suggestedName)
        }
        return destination?.path
    }

    public func browserHandle(_ handle: CEFBrowserHandle, downloadUpdated downloadID: UInt32, path: String, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCanceled: Bool) {
        guard let state else { return }
        let download = CEFDownload(id: downloadID, destination: URL(fileURLWithPath: path), receivedBytes: receivedBytes,
                                   totalBytes: totalBytes, isComplete: isComplete, isCanceled: isCanceled)
        if let index = state.downloads.firstIndex(where: { $0.id == downloadID }) {
            state.downloads[index] = download
        } else {
            state.downloads.append(download)
        }
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
