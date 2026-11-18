import Foundation
import Testing
@testable import CedricCore

@Suite struct VersionTests {
    @Test func sourceIsSemver() {
        let parts = CedricVersion.source.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test func bundleVersionOnlyForCedric() {
        #expect(CedricVersion.resolve(bundleIdentifier: "net.mindtricks.cedric", shortVersion: "9.9.9") == "9.9.9")
        #expect(CedricVersion.resolve(bundleIdentifier: "net.mindtricks.cedric", shortVersion: " ") == CedricVersion.source)
        #expect(CedricVersion.resolve(bundleIdentifier: "com.apple.dt.xctest.tool", shortVersion: "16.0") == CedricVersion.source)
        #expect(CedricVersion.resolve(bundleIdentifier: nil, shortVersion: nil) == CedricVersion.source)
    }

    /// The CHANGELOG has a section for the version this tree says it is,
    /// so a release tag never lacks notes (release.yml checks it again).
    @Test func changelogHasThisVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        #expect(text.contains("\n## [\(CedricVersion.source)]"))
    }
}
