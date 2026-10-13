// Unit tests for the parts of the API that do not need a browser. Tests that drive a real browser are
// in WebView/WebViewTests and run only in a Tart VM (docs/TESTING_IN_TART.md).

import Foundation
import Testing
@testable import CEFWebView

struct JSONDecodingTests {
    @Test func decodesEveryJSONType() throws {
        #expect(try CEFWebViewState.decodeJSON("42") as? Int == 42)
        #expect(try CEFWebViewState.decodeJSON("\"text\"") as? String == "text")
        #expect(try CEFWebViewState.decodeJSON("true") as? Bool == true)
        #expect(try CEFWebViewState.decodeJSON("[1,2]") as? [Int] == [1, 2])
        let object = try CEFWebViewState.decodeJSON("{\"a\":{\"b\":1}}") as? [String: Any]
        #expect((object?["a"] as? [String: Any])?["b"] as? Int == 1)
    }

    @Test func decodesNullAsNil() throws {
        #expect(try CEFWebViewState.decodeJSON("null") == nil)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: (any Error).self) { _ = try CEFWebViewState.decodeJSON("{") }
    }
}

struct ActionTests {
    @Test func navigationActionParsesItsURL() {
        let action = CEFNavigationAction(urlString: "https://example.com/a?b=1", isMainFrame: true,
                                         isUserGesture: false, isRedirect: false)
        #expect(action.url == URL(string: "https://example.com/a?b=1"))
        #expect(action.urlString == "https://example.com/a?b=1")
    }

    @Test func newWindowActionKeepsTheRawURL() {
        let action = CEFNewWindowAction(urlString: "about:blank#popup", isUserGesture: true)
        #expect(action.url == URL(string: "about:blank#popup"))
        #expect(action.urlString == "about:blank#popup")
        #expect(action.isUserGesture)
    }
}

struct DownloadTests {
    @Test func fractionCompletedNeedsAKnownTotal() {
        var download = CEFDownload(id: 1, destination: URL(fileURLWithPath: "/tmp/x"), receivedBytes: 50,
                                   totalBytes: 200, isComplete: false, isCanceled: false)
        #expect(download.fractionCompleted == 0.25)
        download.totalBytes = -1
        #expect(download.fractionCompleted == nil)
    }
}

struct ConfigurationTests {
    @Test func defaultsSuitAShippingApp() {
        let configuration = CEFConfiguration()
        #expect(configuration.sandboxEnabled)
        #expect(configuration.gpuEnabled)
        #expect(!configuration.verboseLogging)
        #expect(!configuration.useSystemKeychain)
        #expect(configuration.profileDirectory == nil)
        #expect(configuration.userAgent == nil)
    }
}

struct LoadErrorTests {
    @Test func describesItself() {
        let error = CEFLoadError(code: -105, description: "net::ERR_NAME_NOT_RESOLVED", url: nil)
        #expect(error.localizedDescription == "net::ERR_NAME_NOT_RESOLVED (error -105)")
        #expect(CEFLoadError(code: -2, description: "", url: nil).localizedDescription == "Load failed (error -2)")
    }
}
