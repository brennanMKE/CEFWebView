// WebViewApp.swift

import SwiftUI
import CEFWebView
import os.log

@main
struct WebViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        print("🚀 WebViewApp.init() called")

        // Handle CEF subprocess roles before any other initialization
        print("🚀 About to call CEFApplication.handleSubprocessIfNeeded()")
        CEFApplication.handleSubprocessIfNeeded()
        print("🚀 Returned from CEFApplication.handleSubprocessIfNeeded()")
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
            print("Failed to initialize CEF: %@", error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CEFApplication.shared.shutdown()
    }
}
