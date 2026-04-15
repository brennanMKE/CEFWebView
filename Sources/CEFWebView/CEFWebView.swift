import AppKit
import CEFWrapper
import SwiftUI

/// Hosting view that tells CEF when SwiftUI/AppKit changes its size (required for SetAsChild / windowed embedding).
private final class CEFBrowserContainerView: NSView {
    /// Match top-left origin with Chromium’s SetAsChild expectations (default NSView is bottom-left).
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        // Report a non-zero intrinsic size so SwiftUI doesn’t collapse the view
        return NSSize(width: 800, height: 600)
    }

    override func layout() {
        super.layout()
        CEFWrapper.notifyBrowserViewGeometryChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CEFWrapper.notifyBrowserViewGeometryChanged()
    }
}

// MARK: - NSViewRepresentable Wrapper

public struct CEFWebView: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var state: CEFWebViewState

    public init(url: Binding<URL?>, state: Binding<CEFWebViewState>) {
        self._url = url
        self._state = state
    }

    public func makeNSView(context: Context) -> NSView {
        print("\n📱 CEFWebView.makeNSView called")

        // Create container view with a default frame
        // The view will be resized by the layout system, but we need a non-zero initial size
        // so CEF doesn't create with (0,0,0,0) dimensions
        let container = CEFBrowserContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.autoresizesSubviews = true

        // Store container for later use
        context.coordinator.container = container
        // Store the initial frame so we can restore it if updateNSView gets zero bounds
        context.coordinator.initialFrame = container.frame

        // Initialize CEF on first use
        do {
            try CEFApplication.shared.initialize()
        } catch let error as NSError {
            let errorDesc = "CEF Initialization Failed: \(error.localizedDescription)"
            print("❌ CEF initialization failed: \(errorDesc)")
            state.initializationError = errorDesc
            return container
        } catch {
            let errorDesc = "CEF Initialization Failed: \(error)"
            print("❌ CEF initialization failed: \(errorDesc)")
            state.initializationError = errorDesc
            return container
        }

        // CEF creates a child NSView inside the container via the Alloy windowed API.
        let initialURL = url ?? URL(string: "about:blank")!
        do {
            let host = try CEFBrowserHost(parentView: container, url: initialURL, state: state)
            context.coordinator.browserHost = host
            CEFApplication.shared.activeBrowserHost = host
            state.setBrowserHost(host)
            state.currentURL = url
            context.coordinator.lastNavigationKeyFromBinding = url.map(Self.stableNavigationKey)
            print("✅ Browser host created with frame: \(container.bounds)")
            // The browser view was already added as a subview of container by CEFWrapper.
        } catch let error as CEFError {
            let errorDesc = error.localizedDescription
            print("❌ Browser creation failed: \(errorDesc)")
            state.initializationError = errorDesc
        } catch {
            let errorDesc = "Browser Creation Failed: \(error)"
            print("❌ Browser creation failed: \(errorDesc)")
            state.initializationError = errorDesc
        }

        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = context.coordinator.browserHost else {
            print("⚠️  updateNSView: No browser host in coordinator")
            return
        }

        // Ensure container fills the parent view (SwiftUI may start at zero size, then assign real bounds).
        if let container = context.coordinator.container {
            print("📐 updateNSView: nsView.bounds=\(nsView.bounds), container.frame was \(container.frame)")
            // Update frame: prefer parent's bounds if non-zero, otherwise restore initial frame
            let newFrame: NSRect
            if !nsView.bounds.isEmpty {
                newFrame = nsView.bounds
                print("📐 updateNSView: Using parent bounds \(newFrame)")
            } else if !context.coordinator.initialFrame.isEmpty {
                newFrame = context.coordinator.initialFrame
                print("📐 updateNSView: Using initial frame \(newFrame) (parent bounds are zero)")
            } else {
                print("📐 updateNSView: Both parent and initial bounds are zero, skipping resize")
                newFrame = container.frame
            }
            container.frame = newFrame
            print("📐 updateNSView: container.frame set to \(container.frame)")
        }
        CEFWrapper.notifyBrowserViewGeometryChanged()

        // Only load when the *binding* navigation intent changes. Compare stable string keys so
        // Optional/URL normalization quirks don’t trigger extra loads; do not compare to
        // `state.currentURL` (redirects diverge from the binding).
        let key = url.map(Self.stableNavigationKey)
        if key != context.coordinator.lastNavigationKeyFromBinding {
            context.coordinator.lastNavigationKeyFromBinding = key
            if let url {
                print("📍 Binding URL changed, loading: \(url.absoluteString)")
                host.loadURL(url)
                state.currentURL = url
            }
        }
    }

    /// Normalized key for “same navigation” so trailing slashes / percent-encoding don’t double-load.
    private static func stableNavigationKey(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        var initialFrame: NSRect = .zero
        /// Stable string form of last applied `$url` (see `stableNavigationKey`).
        var lastNavigationKeyFromBinding: String?
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
