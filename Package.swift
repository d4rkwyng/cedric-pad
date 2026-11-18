// swift-tools-version: 6.0
// 6.0, like Tankard: the newest tools version the macOS 14 Command Line
// Tools (Swift 6.0.x) understand. CI builds with Swift 6.1.
import PackageDescription

let package = Package(
    name: "cedric",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CedricCore", targets: ["CedricCore"]),
        .executable(name: "CedricApp", targets: ["CedricApp"]),
    ],
    targets: [
        // Everything that can be tested without a window: language
        // detection, the tokenizers and highlight engine, the Markdown
        // renderer, encoding and line-ending detection, find/replace, the
        // line index, the session store and the theme palettes. Foundation
        // only; no AppKit.
        .target(name: "CedricCore"),

        // The AppKit app. Scripts/bundle-app.sh wraps it in Cedric.app.
        .executableTarget(
            name: "CedricApp",
            dependencies: ["CedricCore"]
        ),

        .testTarget(
            name: "CedricCoreTests",
            dependencies: ["CedricCore"]
        ),
    ]
)
