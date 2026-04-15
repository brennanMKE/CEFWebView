// WebViewApp.swift

import SwiftUI
import CEFWebView
import os.log

private let appLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "WebViewApp")

@main
struct WebViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        appLogger.info("🚀 WebViewApp.init() called")

        // Handle CEF subprocess roles before any other initialization
        appLogger.info("🚀 About to call CEFApplication.handleSubprocessIfNeeded()")
        CEFApplication.handleSubprocessIfNeeded()
        appLogger.info("🚀 Returned from CEFApplication.handleSubprocessIfNeeded()")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("🚀 AppDelegate.applicationDidFinishLaunching() - initializing CEF")
        do {
            try CEFApplication.shared.initialize()
            appLogger.info("✅ CEF initialized successfully from AppDelegate")
        } catch {
            appLogger.error("❌ Failed to initialize CEF: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLogger.info("🛑 AppDelegate.applicationWillTerminate() - shutting down CEF")
        CEFApplication.shared.shutdown()
    }
}
