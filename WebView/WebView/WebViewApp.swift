// WebViewApp.swift

import SwiftUI
import CEFWebView

@main
struct WebViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Handle CEF subprocess roles before any other initialization
        CEFApplication.handleSubprocessIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try CEFApplication.shared.initialize()
        } catch {
            NSLog("Failed to initialize CEF: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CEFApplication.shared.shutdown()
    }
}
