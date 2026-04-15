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

            // Status bar
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

            // Web view
            CEFWebView(url: $url, state: $webState)
                .background(.white)
        }
    }
}

#Preview {
    ContentView()
}
