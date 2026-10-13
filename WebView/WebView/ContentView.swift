// ContentView.swift

import AppKit
import SwiftUI
import CEFWebView
import os.log

private let contentLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "ContentView")

struct ContentView: View {
    @State private var url: URL?
    @State private var webState = CEFWebViewState()
    @State private var urlInput: String
    @State private var findText = ""
    @State private var showsFindBar = false
    @State private var notice: String?
    @Environment(\.openWindow) private var openWindow

    init(initialURL: URL? = URL(string: "https://thelastoutpostworkshop.github.io/ESPConnect/")) {
        _url = State(initialValue: initialURL)
        _urlInput = State(initialValue: initialURL?.absoluteString ?? "")
    }

    private var statusBarText: String {
        if let notice {
            return notice
        }
        if webState.processStatus.rendererTerminated {
            return "The page's renderer process stopped. Reload to try again."
        }
        if let error = webState.lastError {
            return "Load failed: \(error.localizedDescription)"
        }
        if webState.isLoading {
            return "Loading… \(Int(webState.estimatedProgress * 100))%"
        }
        return webState.title ?? "Ready"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if showsFindBar {
                findBar
            }
            processBar

            if let error = webState.initializationError {
                VStack(alignment: .leading, spacing: 12) {
                    Label("CEF Initialization Error", systemImage: "exclamationmark.circle.fill")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.red.opacity(0.1))
            } else {
                statusBar
            }

            CEFWebView(url: $url, state: $webState)
                .background(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: configureWebView)
        .onChange(of: webState.currentURL) { _, newValue in
            // Keep the field aligned with committed navigations, including redirects.
            if let newValue, !newValue.absoluteString.hasPrefix("data:") {
                urlInput = newValue.absoluteString
            }
        }
        .focusedSceneValue(\.browserCommands, BrowserCommands(
            showDemoPage: { webState.loadHTML(DemoPage.html) },
            countLinks: countLinks,
            incrementCounter: incrementCounter,
            find: { showsFindBar = true },
            zoomIn: { webState.pageZoom = min(webState.pageZoom * 1.2, 5) },
            zoomOut: { webState.pageZoom = max(webState.pageZoom / 1.2, 0.25) },
            actualSize: { webState.pageZoom = 1 },
            deleteCookies: deleteCookies
        ))
    }

    // MARK: - Bars

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { webState.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!webState.canGoBack)

            Button(action: { webState.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!webState.canGoForward)

            if webState.isLoading {
                Button(action: { webState.stopLoading() }) {
                    Image(systemName: "xmark")
                }
            } else {
                Button(action: { webState.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }

            TextField("URL", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let newURL = URL(string: urlInput) {
                        url = newURL
                    }
                }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("Find in page", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { webState.find(findText) }
            if let result = webState.findResult {
                Text(result.matchCount == 0 ? "No matches" : "\(result.activeMatch) of \(result.matchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Previous") { webState.find(findText, backwards: true) }
            Button("Next") { webState.find(findText) }
            Spacer()
            Button("Done") {
                webState.stopFinding()
                showsFindBar = false
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor))
    }

    private var processBar: some View {
        HStack(spacing: 12) {
            Text("Processes:").font(.caption).fontWeight(.semibold)
            HStack(spacing: 8) {
                ForEach(CEFProcessType.allCases, id: \.self) { process in
                    ProcessStatusDot(
                        label: process.rawValue.capitalized,
                        launched: webState.processStatus.launched.contains(process),
                        failed: process == .renderer && webState.processStatus.rendererTerminated
                    )
                }
            }
            Spacer()
            if webState.pageZoom != 1 {
                Text("Zoom \(Int((webState.pageZoom * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.05))
        .border(Color.gray.opacity(0.2), width: 0.5)
    }

    private var statusBar: some View {
        HStack {
            if webState.isLoading {
                ProgressView(value: webState.estimatedProgress)
                    .frame(width: 80)
            }
            Text(statusBarText)
                .font(.caption)
                .foregroundStyle(webState.lastError != nil || webState.processStatus.rendererTerminated ? .red : .secondary)
                .lineLimit(1)
            Spacer()
            if let download = webState.downloads.last {
                Text(downloadText(download))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.1))
    }

    private func downloadText(_ download: CEFDownload) -> String {
        let name = download.destination.lastPathComponent
        if download.isCanceled { return "\(name): canceled" }
        if download.isComplete { return "\(name): done" }
        if let fraction = download.fractionCompleted { return "\(name): \(Int(fraction * 100))%" }
        return "\(name): \(ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file))"
    }

    // MARK: - CEFWebView API

    private func configureWebView() {
        // Links outside the web (mailto:, tel:, app schemes) open in their own app instead.
        webState.navigationPolicy = { action in
            guard action.isMainFrame, let url = action.url, let scheme = url.scheme?.lowercased() else {
                return .allow
            }
            if ["http", "https", "about", "data", "file", "chrome", "blob"].contains(scheme) {
                return .allow
            }
            contentLogger.info("Opening \(url.absoluteString, privacy: .public) outside the web view")
            NSWorkspace.shared.open(url)
            return .cancel
        }

        // Pop-ups get a window of their own.
        webState.newWindowPolicy = { action in
            guard let url = action.url else { return .block }
            openWindow(value: url)
            return .block
        }

        webState.setMessageHandler("greeting") { message in
            let text: String
            if let body = message.body as? [String: Any], let greeting = body["text"] as? String {
                text = greeting
            } else {
                text = String(describing: message.body ?? "nil")
            }
            showNotice("Message from page: \(text)")
        }
    }

    private func countLinks() {
        Task {
            do {
                let count = try await webState.evaluateJavaScript("document.links.length")
                showNotice("This page has \(count ?? 0) links")
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func incrementCounter() {
        Task {
            do {
                // A promise: evaluateJavaScript waits for it.
                let value = try await webState.evaluateJavaScript(
                    "new Promise(resolve => setTimeout(() => resolve(typeof increment === 'function' ? increment() : null), 100))"
                )
                showNotice(value == nil ? "Open Tools → Demo Page first" : "Counter is now \(value!)")
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func deleteCookies() {
        Task {
            let count = await CEFApplication.shared.deleteAllCookies()
            showNotice("Deleted \(count) cookies")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }
}

// MARK: - Menu commands

struct BrowserCommands {
    var showDemoPage: () -> Void
    var countLinks: () -> Void
    var incrementCounter: () -> Void
    var find: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var actualSize: () -> Void
    var deleteCookies: () -> Void
}

extension FocusedValues {
    @Entry var browserCommands: BrowserCommands?
}

struct BrowserMenuCommands: Commands {
    @FocusedValue(\.browserCommands) private var browser

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { browser?.find() }
                .keyboardShortcut("f")
                .disabled(browser == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { browser?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { browser?.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { browser?.actualSize() }
                .keyboardShortcut("0")
        }
        CommandMenu("Tools") {
            Button("Demo Page") { browser?.showDemoPage() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Count Links (JavaScript)") { browser?.countLinks() }
            Button("Increment Counter (Promise)") { browser?.incrementCounter() }
            Divider()
            Button("Delete All Cookies") { browser?.deleteCookies() }
        }
    }
}

// MARK: - Process status

struct ProcessStatusDot: View {
    let label: String
    let launched: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(failed ? .red : launched ? .green : .gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(failed || launched ? .primary : .secondary)
        }
    }
}

#Preview {
    ContentView()
}
