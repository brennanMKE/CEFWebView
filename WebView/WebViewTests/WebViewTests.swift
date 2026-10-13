// WebViewTests.swift
//
// Integration tests for CEFWebView's API. They run inside WebView.app (the test host), where CEF is
// initialized and the helper apps are installed, and drive a real browser in an offscreen window.

import AppKit
import Foundation
import SwiftUI
import Testing
@_spi(Testing) import CEFWebView

// MARK: - Harness

/// One CEFWebView in its own window.
@MainActor
final class Browser {
    let state = CEFWebViewState()
    private let window: NSWindow

    /// Open a browser showing `html`, and wait until the page has set its title to `title`.
    init(html: String, title: String = "ready") async throws {
        let page = "<!doctype html><html><head><meta charset='utf-8'><title>\(title)</title></head><body>\(html)</body></html>"
        let url = URL(string: "data:text/html;charset=utf-8;base64,\(Data(page.utf8).base64EncodedString())")!
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CEFWebView(url: .constant(url), state: .constant(state)))
        // Visible: CEF does not highlight find matches in a window that is not on screen.
        window.orderFrontRegardless()
        try await waitUntil("the page loads") { self.state.title == title && !self.state.isLoading }
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// Poll `condition` while the main run loop (and CEF's message pump) keeps running.
    func waitUntil(_ what: String, timeout: Duration = .seconds(20),
                   _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                throw HarnessError.timedOut(what)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Make this the key window of the active app.
    func focus() async throws {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Run a script for its side effects in the page.
    func run(_ script: String) async throws {
        _ = try await state.evaluateJavaScript("(() => { \(script); return null })()")
    }
}


enum HarnessError: Error {
    case timedOut(String)
}

// MARK: - Tests

/// Serialized: every test drives the one CEF instance on the main thread.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CEFWebViewAPITests {

    // MARK: JavaScript evaluation

    @Test func evaluatesValuesOfEachJSONType() async throws {
        let browser = try await Browser(html: "<p id='p'>Hello</p>")
        defer { browser.close() }

        #expect(try await browser.state.evaluateJavaScript("1 + 2") as? Int == 3)
        #expect(try await browser.state.evaluateJavaScript("document.getElementById('p').textContent") as? String == "Hello")
        #expect(try await browser.state.evaluateJavaScript("true") as? Bool == true)
        #expect(try await browser.state.evaluateJavaScript("undefined") == nil)
        #expect(try await browser.state.evaluateJavaScript("null") == nil)

        let array = try await browser.state.evaluateJavaScript("[1, 'two', {three: 3}]") as? [Any]
        #expect(array?.count == 3)
        #expect(array?[1] as? String == "two")

        let object = try await browser.state.evaluateJavaScript("({name: 'cef', nested: {ok: true}})") as? [String: Any]
        #expect(object?["name"] as? String == "cef")
        #expect((object?["nested"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func awaitsPromises() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        let value = try await browser.state.evaluateJavaScript(
            "new Promise(resolve => setTimeout(() => resolve('later'), 50))")
        #expect(value as? String == "later")
    }

    @Test func throwsForExceptionsAndRejections() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        await #expect(throws: CEFJavaScriptError.self) {
            _ = try await browser.state.evaluateJavaScript("throw new Error('boom')")
        }
        do {
            _ = try await browser.state.evaluateJavaScript("Promise.reject(new Error('rejected'))")
            Issue.record("Expected a rejection")
        } catch let error as CEFJavaScriptError {
            #expect(error == .exception("rejected"))
        }
        do {
            _ = try await browser.state.evaluateJavaScript("const a = {}; a.self = a; a")
            Issue.record("Expected a cyclic-object error")
        } catch let error as CEFJavaScriptError {
            guard case .exception = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
    }

    // MARK: Script messages

    @Test func deliversScriptMessagesToTheirHandler() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        var received: [CEFScriptMessage] = []
        browser.state.setMessageHandler("ping") { received.append($0) }

        try await browser.run("cefWebView.postMessage('ping', {count: 1, tags: ['a', 'b']})")
        try await browser.run("cefWebView.postMessage('unhandled', 1)")
        try await browser.run("cefWebView.postMessage('ping')")
        try await browser.waitUntil("two ping messages") { received.count == 2 }

        let body = received[0].body as? [String: Any]
        #expect(received[0].name == "ping")
        #expect(received[0].isMainFrame)
        #expect(body?["count"] as? Int == 1)
        #expect(body?["tags"] as? [String] == ["a", "b"])
        #expect(received[1].body == nil)
    }

    @Test func reportsWhetherAMessageCameFromAnIframe() async throws {
        let browser = try await Browser(html: "<iframe src='about:blank'></iframe>")
        defer { browser.close() }

        var received: [CEFScriptMessage] = []
        browser.state.setMessageHandler("frame") { received.append($0) }
        try await browser.run("document.querySelector('iframe').contentWindow.cefWebView.postMessage('frame', 'hi')")
        try await browser.waitUntil("a message from the iframe") { !received.isEmpty }
        #expect(received.first?.isMainFrame == false)
        #expect(received.first?.body as? String == "hi")
    }

    /// CEF 154: a `srcdoc` iframe inside a page loaded from a `data:` URL (as `loadHTML(_:)` does)
    /// crashes the renderer with a CHECK failure. `srcdoc` in an https page, and `about:blank` or
    /// `data:` iframes in a `data:` page, are fine. Not caused by CEFWebView's script bridge: it
    /// crashes with the bridge off too.
    @Test func srcdocIframeInDataURLPageCrashesTheRenderer() async throws {
        let browser = try await Browser(html: "<iframe srcdoc='<p>hi</p>'></iframe>")
        defer { browser.close() }
        try await Task.sleep(for: .seconds(2))
        withKnownIssue("CEF crashes a renderer that loads a srcdoc iframe in a data: URL page") {
            #expect(browser.state.processStatus.rendererTerminated == false)
        }
    }

    // MARK: Navigation policy

    @Test func navigationPolicyCanCancelMainFrameAndIframeNavigations() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        var actions: [CEFNavigationAction] = []
        browser.state.navigationPolicy = { action in
            actions.append(action)
            return action.urlString.contains("blocked") ? .cancel : .allow
        }

        try await browser.run("location.href = 'https://cefwebview.invalid/blocked'")
        try await browser.waitUntil("the main-frame navigation is decided") {
            actions.contains { $0.isMainFrame && $0.urlString.contains("blocked") }
        }

        try await browser.run("""
            const frame = document.createElement('iframe');
            frame.src = 'https://cefwebview.invalid/blocked-frame';
            document.body.appendChild(frame)
            """)
        try await browser.waitUntil("the iframe navigation is decided") {
            actions.contains { !$0.isMainFrame && $0.urlString.contains("blocked-frame") }
        }

        // Both were canceled: the page is still the original one.
        #expect(try await browser.state.evaluateJavaScript("document.title") as? String == "ready")
        #expect(browser.state.title == "ready")
    }

    // MARK: Pop-ups
    //
    // Chromium blocks pop-ups that no user gesture started, so these open them as user gestures.

    @Test func newWindowPolicyReceivesPopups() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        var popups: [CEFNewWindowAction] = []
        browser.state.newWindowPolicy = { action in
            popups.append(action)
            return .block
        }
        browser.state.runScriptAsUserGesture("window.open('https://cefwebview.invalid/popup')")
        try await browser.waitUntil("the pop-up request") { !popups.isEmpty }
        #expect(popups.first?.url == URL(string: "https://cefwebview.invalid/popup"))
        #expect(browser.state.title == "ready")
    }

    @Test func popupsLoadInPlaceByDefault() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        // Cancel the in-place navigation so the test does not need the network.
        var navigations: [CEFNavigationAction] = []
        browser.state.navigationPolicy = { action in
            navigations.append(action)
            return .cancel
        }
        browser.state.runScriptAsUserGesture("window.open('https://cefwebview.invalid/in-place')")
        try await browser.waitUntil("the pop-up loads in this view") {
            navigations.contains { $0.isMainFrame && $0.urlString == "https://cefwebview.invalid/in-place" }
        }
    }

    // MARK: Loading

    @Test func reportsLoadErrors() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        browser.state.load(URL(string: "https://cefwebview.invalid/")!)
        try await browser.waitUntil("the load fails") { browser.state.lastError != nil }
        #expect(browser.state.lastError!.code < 0)
        #expect(browser.state.isLoading == false)
    }

    @Test func loadsHTMLStrings() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        browser.state.loadHTML("<title>second</title><p>Second page</p>")
        try await browser.waitUntil("the second page loads") { browser.state.title == "second" }
        #expect(browser.state.canGoBack)
        #expect(browser.state.estimatedProgress == 1)
    }

    // MARK: Find, zoom

    @Test func findsTextInThePage() async throws {
        let browser = try await Browser(html: "<p>apple banana apple cherry apple</p>")
        defer { browser.close() }

        try await browser.focus()
        browser.state.find("apple")
        try await browser.waitUntil("the first match is selected") {
            browser.state.findResult == CEFFindResult(matchCount: 3, activeMatch: 1)
        }

        browser.state.find("apple")
        try await browser.waitUntil("the next match") { browser.state.findResult?.activeMatch == 2 }

        browser.state.stopFinding()
        #expect(browser.state.findResult == nil)
    }

    @Test func zoomScalesThePage() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        let ratio = try await browser.state.evaluateJavaScript("window.devicePixelRatio") as? Double ?? 0
        browser.state.pageZoom = 1.2
        var zoomed = ratio
        for _ in 0..<100 where zoomed < ratio * 1.1 {
            try await Task.sleep(for: .milliseconds(50))
            zoomed = try await browser.state.evaluateJavaScript("window.devicePixelRatio") as? Double ?? 0
        }
        #expect(abs(zoomed / ratio - 1.2) < 0.05)
    }

    // MARK: Downloads

    @Test func downloadsToTheChosenDestination() async throws {
        let browser = try await Browser(html: "<a id='file' href='data:text/plain,hello%20download' download='hello.txt'>file</a>")
        defer { browser.close() }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var requests: [CEFDownloadRequest] = []
        browser.state.downloadPolicy = { request in
            requests.append(request)
            return folder.appendingPathComponent(request.suggestedFilename)
        }
        try await browser.run("document.getElementById('file').click()")
        try await browser.waitUntil("the download completes") { browser.state.downloads.first?.isComplete == true }

        #expect(requests.first?.suggestedFilename == "hello.txt")
        let saved = try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(saved == "hello download")
    }

    @Test func downloadPolicyCanCancel() async throws {
        let browser = try await Browser(html: "<a id='file' href='data:text/plain,nope' download='nope.txt'>file</a>")
        defer { browser.close() }

        var asked = false
        browser.state.downloadPolicy = { _ in
            asked = true
            return nil
        }
        try await browser.run("document.getElementById('file').click()")
        try await browser.waitUntil("the download is offered") { asked }
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.state.downloads.isEmpty)
    }

    // MARK: Process status

    @Test func reportsLaunchedProcesses() async throws {
        let browser = try await Browser(html: "")
        defer { browser.close() }

        #expect(browser.state.processStatus.launched.contains(.renderer))
        #expect(browser.state.processStatus.rendererTerminated == false)
    }
}
