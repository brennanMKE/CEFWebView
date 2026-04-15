// ContentView.swift

import SwiftUI
import CEFWebView

struct ContentView: View {
    @State private var url: URL? = URL(string: "https://google.com")
    @State private var webState = CEFWebViewState()
    @State private var urlInput: String = "https://google.com"

    var body: some View {
        VStack(spacing: 0) {
            // Navigation toolbar
            HStack(spacing: 12) {
                Button(action: { webState.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!webState.canGoBack)

                Button(action: { webState.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!webState.canGoForward)

                Button(action: { webState.reload() }) {
                    Image(systemName: "arrow.clockwise")
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

            // Error display (if CEF initialization failed)
            if let error = webState.initializationError {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("CEF Initialization Error")
                            .font(.headline)
                        Spacer()
                    }
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .border(Color.red.opacity(0.3))
            } else {
                // Status bar (only show if no error)
                HStack {
                    if webState.isLoading {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .leading)
                    }
                    Text(webState.title ?? "Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
            }

            // Web view — sizes to fill remaining space
            CEFWebView(url: $url, state: $webState)
                .background(.white)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { newSize in
                    print("📐 CEFWebView geometry changed: \(newSize)")
                }
        }
        .onAppear {
            urlInput = url?.absoluteString ?? ""
        }
        .onChange(of: url) { _, newValue in
            // Keep the field aligned with committed navigations (don’t require a second submit after redirects).
            urlInput = newValue?.absoluteString ?? ""
        }
    }
}

#Preview {
    ContentView()
}
