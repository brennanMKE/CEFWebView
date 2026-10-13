// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// MARK: - CEF framework release
//
// Package versions are <CEF major>.<CEF patch>.<package revision>: CEF 154.0.34 ships as 154.34.0, a
// package-only fix as 154.34.1. Scripts/update_cef.sh builds the zip and prints its checksum; it is
// uploaded to the GitHub release whose tag is `releaseTag`.
let releaseTag = "154.34.0"
let cefChecksum = "c538e2a048ca241817076a92b26bb53be420074c910a3eb2d1bb53eb908c8e40"

/// Maintainers build the framework locally with Scripts/update_cef.sh (git-ignored); everyone else
/// downloads the release artifact.
let localCEFXCFramework = "Frameworks/ChromiumEmbeddedFramework.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let chromiumEmbeddedFramework: Target =
    FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(localCEFXCFramework).path)
    ? .binaryTarget(name: "ChromiumEmbeddedFramework", path: localCEFXCFramework)
    : .binaryTarget(
        name: "ChromiumEmbeddedFramework",
        url: "https://github.com/brennanMKE/CEFWebView/releases/download/\(releaseTag)/ChromiumEmbeddedFramework.xcframework.zip",
        checksum: cefChecksum
    )

let package = Package(
    name: "CEFWebView",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "CEFWebView",
            targets: ["CEFWebView"]
        ),
        // Subprocess executable for CEF's helper apps. Scripts/cef-embed builds it and copies it into
        // the host app as "<App> Helper.app" and its (GPU), (Renderer) and (Alerts) variants.
        .executable(name: "CEFHelper", targets: ["CEFHelper"]),
    ],
    targets: [
        // MARK: - CEFDLLWrapper: CEF's C++ wrapper (libcef_dll_wrapper), vendored from the CEF distribution
        //
        // The CEF framework itself is never linked: CefScopedLibraryLoader opens it at runtime and these
        // sources forward every cef_* call to it. CEF includes its headers as "include/...", so dependents
        // add this directory as a header search path; include/module.modulemap exports no headers, which
        // keeps the C++ API out of Swift.
        .target(
            name: "CEFDLLWrapper",
            path: "Sources/CEFDLLWrapper",
            exclude: ["LICENSE.txt"],
            sources: ["libcef_dll"],
            cxxSettings: [
                .headerSearchPath("."),
                .define("WRAPPING_CEF_SHARED"),
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
            ]
        ),

        // MARK: - ChromiumEmbeddedFramework: the CEF runtime (~320 MB), embedded and signed by Xcode
        chromiumEmbeddedFramework,

        // MARK: - CEFWrapper: ObjC++ bridge to CEF C++ API
        .target(
            name: "CEFWrapper",
            dependencies: ["CEFDLLWrapper"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../CEFDLLWrapper"),
            ]
        ),

        // MARK: - CEFWebView: Swift library target (public API)
        .target(
            name: "CEFWebView",
            // Depending on the framework is what makes Xcode embed it in the host app. CEFHelper does
            // not, so building the helper never needs it.
            dependencies: ["CEFWrapper", "ChromiumEmbeddedFramework"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),

        // MARK: - CEFHelper: one executable for every helper role (CEF picks the role from --type=)
        .executableTarget(
            name: "CEFHelper",
            dependencies: ["CEFWrapper"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "CEFWebViewTests",
            dependencies: ["CEFWebView"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20
)
