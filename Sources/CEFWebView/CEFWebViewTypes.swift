import Foundation

// MARK: - Navigation

/// A navigation the page or the user is about to start, passed to `CEFWebViewState.navigationPolicy`.
nonisolated public struct CEFNavigationAction: Sendable, Equatable {
    /// The destination. `nil` if CEF reports a URL that `URL` cannot parse.
    public let url: URL?
    /// The destination exactly as CEF reports it.
    public let urlString: String
    /// `false` for iframes.
    public let isMainFrame: Bool
    /// The navigation followed a click, key press or other user action.
    public let isUserGesture: Bool
    /// The navigation is a server redirect of an earlier one.
    public let isRedirect: Bool

    public init(urlString: String, isMainFrame: Bool, isUserGesture: Bool, isRedirect: Bool) {
        self.url = URL(string: urlString)
        self.urlString = urlString
        self.isMainFrame = isMainFrame
        self.isUserGesture = isUserGesture
        self.isRedirect = isRedirect
    }
}

nonisolated public enum CEFNavigationPolicy: Sendable {
    case allow
    case cancel
}

// MARK: - Pop-ups

/// A page's request to open a pop-up or new window (`window.open`, `target="_blank"`).
nonisolated public struct CEFNewWindowAction: Sendable, Equatable {
    public let url: URL?
    public let urlString: String
    public let isUserGesture: Bool

    public init(urlString: String, isUserGesture: Bool) {
        self.url = URL(string: urlString)
        self.urlString = urlString
        self.isUserGesture = isUserGesture
    }
}

nonisolated public enum CEFNewWindowPolicy: Sendable {
    /// Load the URL in this view instead of a new window. The default.
    case loadInPlace
    /// Ignore the request. To show the page in a new window, open your own `CEFWebView` with
    /// `action.url` and return this. The new page has no `window.opener`.
    case block
}

// MARK: - JavaScript

/// A message a page sent with `window.cefWebView.postMessage(name, body)`.
nonisolated public struct CEFScriptMessage {
    public let name: String
    /// `body` decoded from JSON: `String`, `NSNumber`, `[Any]`, `[String: Any]`, or `nil` for
    /// `null` and `undefined`.
    public let body: Any?
    /// `false` when an iframe sent the message.
    public let isMainFrame: Bool
}

nonisolated public enum CEFJavaScriptError: Error, Equatable, LocalizedError {
    /// The script threw, or the promise it returned was rejected.
    case exception(String)
    /// The page went away (navigation, crash, close) before the script finished.
    case pageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .exception(let message): "JavaScript error: \(message)"
        case .pageUnavailable(let reason): reason
        }
    }
}

// MARK: - Load errors

/// A failed main-frame load. `code` is a Chromium net error, for example -105 for a name that does not
/// resolve.
nonisolated public struct CEFLoadError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int
    public let description: String
    public let url: URL?

    public var errorDescription: String? {
        description.isEmpty ? "Load failed (error \(code))" : "\(description) (error \(code))"
    }
}

// MARK: - Find in page

nonisolated public struct CEFFindResult: Equatable, Sendable {
    /// Number of matches on the page.
    public let matchCount: Int
    /// 1-based index of the highlighted match, or 0 when there are none.
    public let activeMatch: Int

    public init(matchCount: Int, activeMatch: Int) {
        self.matchCount = matchCount
        self.activeMatch = activeMatch
    }
}

// MARK: - Downloads

/// A download the page started, passed to `CEFWebViewState.downloadPolicy`.
nonisolated public struct CEFDownloadRequest: Sendable, Equatable {
    public let url: URL?
    public let suggestedFilename: String
    public let mimeType: String
}

/// A download in progress or finished, listed in `CEFWebViewState.downloads`.
nonisolated public struct CEFDownload: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let destination: URL
    public var receivedBytes: Int64
    /// -1 when the server did not say.
    public var totalBytes: Int64
    public var isComplete: Bool
    public var isCanceled: Bool

    /// 0...1, or `nil` when the total size is unknown.
    public var fractionCompleted: Double? {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : nil
    }
}

// MARK: - Processes

/// Chromium helper processes. They are shared by every view.
nonisolated public enum CEFProcessType: String, Sendable, CaseIterable {
    case gpu
    case network
    case storage
    case renderer
}

nonisolated public struct CEFProcessStatus: Equatable, Sendable {
    /// Helper processes CEF has launched since it was initialized.
    public var launched: Set<CEFProcessType> = []
    /// The renderer for this view exited abnormally. Reloading starts a new one.
    public var rendererTerminated = false

    public init() {}
}
