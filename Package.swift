// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CEFWebView",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "CEFWebView",
            targets: ["CEFWebView"]
        ),
    ],
    targets: [
        // MARK: - CEFWrapper: ObjC++ bridge to CEF C++ API
        .target(
            name: "CEFWrapper",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Frameworks/include"),
                .headerSearchPath("../../Frameworks"),
                .unsafeFlags(["-std=c++20"])
            ],
            linkerSettings: [
                .linkedLibrary("cef_dll_wrapper"),
                .linkedFramework("Chromium Embedded Framework"),
                .unsafeFlags([
                    "-L../../Frameworks",
                    "-rpath", "@executable_path/../Frameworks"
                ])
            ]
        ),

        // MARK: - CEFWebView: Swift library target (public API)
        .target(
            name: "CEFWebView",
            dependencies: ["CEFWrapper"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "CEFWebViewTests",
            dependencies: ["CEFWebView"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
