import SwiftUI

// MARK: - NSViewRepresentable Wrapper

public struct CEFWebView: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var state: CEFWebViewState

    @MainActor
    public init(url: Binding<URL?>, state: Binding<CEFWebViewState>) {
        self._url = url
        self._state = state
    }

    public func makeNSView(context: Context) -> NSView {
        print("\n📱 CEFWebView.makeNSView called")

        // Initialize CEF on first use
        do {
            try CEFApplication.shared.initialize()
        } catch {
            print("❌ CEF initialization failed: \(error)")
            return NSView()
        }

        // Create container view with a default frame
        // The view will be resized by the layout system, but we need a non-zero initial size
        // so CEF doesn't create with (0,0,0,0) dimensions
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.autoresizesSubviews = true

        // Store container for later use
        context.coordinator.container = container

        // CEF creates a child NSView inside the container via the Alloy windowed API.
        let initialURL = url ?? URL(string: "about:blank")!
        do {
            let host = try CEFBrowserHost(parentView: container, url: initialURL, state: state)
            context.coordinator.browserHost = host
            CEFApplication.shared.activeBrowserHost = host
            state.setBrowserHost(host)
            print("✓ Browser host created with frame: \(container.bounds)")
            // The browser view was already added as a subview of container by CEFWrapper.
        } catch {
            print("❌ Browser creation failed: \(error)")
        }

        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = context.coordinator.browserHost else {
            print("⚠️  updateNSView: No browser host in coordinator")
            return
        }

        // Ensure container fills the parent view
        if let container = context.coordinator.container {
            container.frame = nsView.bounds
        }

        // Handle URL changes
        if let url = url, url != state.currentURL {
            print("📍 URL changed in updateNSView, loading: \(url.absoluteString)")
            host.loadURL(url)
            state.currentURL = url
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.browserHost?.close()
        CEFApplication.shared.activeBrowserHost = nil
    }

    public class Coordinator {
        var browserHost: CEFBrowserHost?
        var container: NSView?
    }
}

#Preview {
    @Previewable @State var url: URL? = URL(string: "https://google.com")
    @Previewable @State var state = CEFWebViewState()

    VStack {
        HStack {
            Button(action: { state.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!state.canGoBack)

            Button(action: { state.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!state.canGoForward)

            Button(action: { state.reload() }) {
                Image(systemName: "arrow.clockwise")
            }

            TextField("URL", value: $url, format: .url)
                .textFieldStyle(.roundedBorder)
        }
        .padding()

        CEFWebView(url: $url, state: $state)
    }
}
