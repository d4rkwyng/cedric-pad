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
        .library(name: "CedricAI", targets: ["CedricAI"]),
        .executable(name: "CedricApp", targets: ["CedricApp"]),
    ],
    targets: [
        // Everything that can be tested without a window: language
        // detection, the tokenizers and highlight engine, the Markdown
        // renderer, encoding and line-ending detection, find/replace, the
        // line index, the session store and the theme palettes. Foundation
        // only; no AppKit.
        .target(name: "CedricCore"),

        // The owl's optional local-AI hint provider: an OpenAI-compatible
        // client for LM Studio / Ollama (localhost or LAN, never cloud), the
        // "only checks so often" scheduler, and an Apple Foundation Models
        // stub. Foundation + URLSession + IOKit only. OFF by default.
        .target(
            name: "CedricAI",
            dependencies: ["CedricCore"]
        ),

        // The AppKit app. Scripts/bundle-app.sh wraps it in Cedric.app.
        .executableTarget(
            name: "CedricApp",
            dependencies: ["CedricCore", "CedricAI"]
        ),

        .testTarget(
            name: "CedricCoreTests",
            dependencies: ["CedricCore"]
        ),
        .testTarget(
            name: "CedricAITests",
            dependencies: ["CedricAI", "CedricCore"]
        ),
    ]
)
