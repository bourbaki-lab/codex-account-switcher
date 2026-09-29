import Foundation
import XCTest
@testable import CodexAccountSwitcherCore

final class OfficialAppLayoutTests: XCTestCase {
    private let legacy = "Contents/Resources/codex"
    private let native = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    private let launcher = "Contents/Resources/codex-cli/bin/codex"

    private func fixture(
        root: URL,
        binaries: [String],
        bundleID: String = "com.openai.codex",
        executable: Bool = true
    ) throws -> URL {
        let app = root.appending(path: "Renamed App.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
        )
        try plist.write(to: app.appending(path: "Contents/Info.plist"))
        for relativePath in binaries {
            let binary = app.appending(path: relativePath)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path
            )
        }
        return app
    }

    func testDetectsNestedNativeCLI() throws {
        let root = try TestFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try fixture(root: root, binaries: [native])
        let locator = OfficialAppLocator(searchRoots: [root])
        XCTAssertNotNil(locator.locate())
        let result = locator.inspect(appURL: app)
        XCTAssertEqual(result?.path, app.path)
        XCTAssertEqual(result?.bundledCodexPath, app.appending(path: native).path)
    }

    func testFallsBackToPackagedLauncher() throws {
        let root = try TestFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try fixture(root: root, binaries: [launcher])
        XCTAssertEqual(
            OfficialAppLocator(searchRoots: [root]).inspect(appURL: app)?.bundledCodexPath,
            app.appending(path: launcher).path
        )
    }

    func testPrefersNativeOverLauncherAndLegacy() throws {
        let root = try TestFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try fixture(root: root, binaries: [legacy, native, launcher])
        XCTAssertEqual(
            OfficialAppLocator(searchRoots: [root]).inspect(appURL: app)?.bundledCodexPath,
            app.appending(path: native).path
        )
    }

    func testRejectsNonExecutablePackagedCLI() throws {
        let root = try TestFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root: root, binaries: [native, launcher], executable: false)
        XCTAssertNil(OfficialAppLocator(searchRoots: [root]).locate())
    }

    func testRejectsOtherVendorWithSameLayout() throws {
        let root = try TestFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root: root, binaries: [native], bundleID: "com.example.other")
        XCTAssertNil(OfficialAppLocator(searchRoots: [root]).locate())
    }
}
