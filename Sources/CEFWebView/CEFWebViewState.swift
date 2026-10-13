import Foundation
import SwiftUI

// MARK: - Observable State

/// The state of one `CEFWebView`, and the way to control it: navigation, JavaScript, script messages,
/// pop-ups, find in page, zoom and downloads.
@MainActor
@Observable
public final class CEFWebViewState {
    public var isLoading: Bool = false
    /// 0...1 while a page loads.
    public var estimatedProgress: Double = 0.0
    public var title: String?
    public var currentURL: URL?
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    /// Set if CEF initialization or browser creation failed.
    public var initializationError: String?

    /// The last main-frame load failure. Cleared when a new load starts.
    public var lastError: CEFLoadError?

    /// Which helper processes are running, and whether this view's renderer crashed.
    public var processStatus = CEFProcessStatus()

    /// Progress of the last `find(_:)`.
    public var findResult: CEFFindResult?

    /// Downloads started from this view, oldest first.
    public var downloads: [CEFDownload] = []

    /// Page zoom: 1 is 100%.
    public var pageZoom: Double = 1.0 {
        didSet {
            guard pageZoom != oldValue, pageZoom > 0 else { return }
            browserHost?.zoomLevel = log(pageZoom) / log(1.2)
        }
    }

    // MARK: Policies

    /// Decides every navigation before it starts, in any frame. `nil` allows everything.
    @ObservationIgnored
    public var navigationPolicy: (@MainActor (CEFNavigationAction) -> CEFNavigationPolicy)?

    /// Decides pop-ups and new windows. `nil` loads them in this view.
    @ObservationIgnored
    public var newWindowPolicy: (@MainActor (CEFNewWindowAction) -> CEFNewWindowPolicy)?

    /// Chooses where a download is saved; return `nil` to cancel it. `nil` saves to ~/Downloads.
    @ObservationIgnored
    public var downloadPolicy: (@MainActor (CEFDownloadRequest) -> URL?)?

    @ObservationIgnored
    private var messageHandlers: [String: @MainActor (CEFScriptMessage) -> Void] = [:]

    @ObservationIgnored
    private weak var browserHost: CEFBrowserHost?

    @ObservationIgnored
    private var lastFindText: String?

    public init() {}

    internal func setBrowserHost(_ host: CEFBrowserHost) {
        self.browserHost = host
        if pageZoom != 1.0 {
            host.zoomLevel = log(pageZoom) / log(1.2)
        }
    }

    /// Clears the previous main-frame failure when a new navigation starts.
    internal func clearLoadError() {
        lastError = nil
        processStatus.rendererTerminated = false
    }

    // MARK: Navigation

    /// Load `url`. Usually you set the view's `url` binding instead.
    public func load(_ url: URL) {
        browserHost?.loadURL(url)
    }

    /// Load an HTML string as a `data:` URL. Relative links in it do not resolve, and CEF 154 crashes the
    /// renderer if the page contains a `srcdoc` iframe.
    public func loadHTML(_ html: String) {
        let encoded = Data(html.utf8).base64EncodedString()
        if let url = URL(string: "data:text/html;charset=utf-8;base64,\(encoded)") {
            load(url)
        }
    }

    public func reload() {
        browserHost?.reload()
    }

    public func stopLoading() {
        browserHost?.stopLoading()
    }

    public func goBack() {
        browserHost?.goBack()
    }

    public func goForward() {
        browserHost?.goForward()
    }

    // MARK: JavaScript

    /// Run `script` in the main frame and return its result. A returned promise is awaited.
    ///
    /// The result crosses from the page as JSON, so it comes back as `String`, `NSNumber`, `[Any]`,
    /// `[String: Any]`, or `nil` for `null` and `undefined`. Values JSON cannot hold (functions, DOM
    /// nodes) become `nil` or `{}`.
    public func evaluateJavaScript(_ script: String) async throws -> Any? {
        guard let browserHost else {
            throw CEFJavaScriptError.pageUnavailable("The view has no browser yet")
        }
        guard let json = try await browserHost.evaluateJavaScript(script) else {
            return nil
        }
        return try Self.decodeJSON(json)
    }

    /// Run `script` as if the user had just clicked, so it may open pop-ups. For tests.
    @_spi(Testing)
    public func runScriptAsUserGesture(_ script: String) {
        browserHost?.runScriptAsUserGesture(script)
    }

    /// Handle `window.cefWebView.postMessage(name, body)` calls with this `name`. Pass `nil` to remove.
    public func setMessageHandler(_ name: String, _ handler: (@MainActor (CEFScriptMessage) -> Void)?) {
        messageHandlers[name] = handler
    }

    internal func receiveScriptMessage(name: String, bodyJSON: String?, isMainFrame: Bool) {
        guard let handler = messageHandlers[name] else {
            cefLogger.debug("No message handler for '\(name, privacy: .public)'")
            return
        }
        var body: Any?
        if let bodyJSON {
            body = try? Self.decodeJSON(bodyJSON)
        }
        handler(CEFScriptMessage(name: name, body: body, isMainFrame: isMainFrame))
    }

    nonisolated static func decodeJSON(_ json: String) throws -> Any? {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        return value is NSNull ? nil : value
    }

    // MARK: Find in page

    /// Highlight matches of `text`. Calling again with the same text moves to the next match.
    public func find(_ text: String, backwards: Bool = false, matchCase: Bool = false) {
        guard !text.isEmpty else {
            stopFinding()
            return
        }
        if text != lastFindText {
            // A new search highlights every match but selects none; the follow-up selects the first.
            lastFindText = text
            browserHost?.find(text, forward: !backwards, matchCase: matchCase, findNext: false)
        }
        browserHost?.find(text, forward: !backwards, matchCase: matchCase, findNext: true)
    }

    public func stopFinding() {
        lastFindText = nil
        findResult = nil
        browserHost?.stopFinding()
    }

    // MARK: Downloads

    public func cancelDownload(_ id: CEFDownload.ID) {
        browserHost?.cancelDownload(id)
    }
}
