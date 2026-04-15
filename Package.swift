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
                    "-F../../../Frameworks",
                    "-L../../../Frameworks",
                    "-rpath", "@executable_path/../Frameworks"
                ])
            ]
        ),

        // MARK: - CEFWebView: Swift library target (public API)
        .target(
            name: "CEFWebView",
            dependencies: ["CEFWrapper"],
            swiftSettings: [
                // Enable multi-process mode by default
                // Consuming apps can override this via their package dependency settings
                .define("CEF_MULTI_PROCESS")
            ]
        ),

        // MARK: - CEFHelper: General helper executable (GPU, utility, network processes)
        .executableTarget(
            name: "CEFHelper",
            path: "Sources/CEFHelper",
            cSettings: [
                .headerSearchPath("../../Frameworks/include")
            ],
            linkerSettings: [
                .linkedFramework("Chromium Embedded Framework"),
                .unsafeFlags(["-F../../../Frameworks"])
            ]
        ),

        // MARK: - CEFHelperRenderer: Renderer process helper executable
        .executableTarget(
            name: "CEFHelperRenderer",
            path: "Sources/CEFHelperRenderer",
            cSettings: [
                .headerSearchPath("../../Frameworks/include")
            ],
            linkerSettings: [
                .linkedFramework("Chromium Embedded Framework"),
                .unsafeFlags(["-F../../../Frameworks"])
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
