import SwiftUI

// MARK: - Observable State

@MainActor
@Observable
public final class CEFWebViewState {
    public var isLoading: Bool = false
    public var estimatedProgress: Double = 0.0
    public var title: String?
    public var currentURL: URL?
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    /// Error message if CEF initialization or browser creation failed. Non-nil indicates a critical failure.
    public var initializationError: String?

    private weak var browserHost: CEFBrowserHost?

    public init() {}

    internal func setBrowserHost(_ host: CEFBrowserHost) {
        self.browserHost = host
    }

    public func reload() {
        browserHost?.reload()
    }

    public func goBack() {
        browserHost?.goBack()
    }

    public func goForward() {
        browserHost?.goForward()
    }
}
