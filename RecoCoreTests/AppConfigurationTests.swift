import Foundation
import XCTest

@testable import RecoCore

final class AppConfigurationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testMissingFileLoadsDefaultsWithoutCreatingAFile() throws {
        let store = makeStore()

        XCTAssertEqual(try store.load(), .defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(try store.entries(changesOnly: true).isEmpty)
    }

    func testSetPersistsOnlyValuesThatDifferFromDefaults() throws {
        let store = makeStore()

        let configuration = try store.set(.showMenuBarIcon, value: "false")

        XCTAssertFalse(configuration.showMenuBarIcon)
        let source = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(source.contains("show-menu-bar-icon = false"))
        XCTAssertFalse(source.contains("hotkey ="))
        XCTAssertEqual(try store.entry(for: .showMenuBarIcon).source, .user)
        XCTAssertEqual(try store.entry(for: .hotkey).source, .defaults)
    }

    func testSettingDefaultRemovesOverrideFile() throws {
        let store = makeStore()
        try store.set(.showMenuBarIcon, value: "false")

        try store.set(.showMenuBarIcon, value: "true")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.load(), .defaults)
    }

    func testHotkeyAliasesAreCanonicalized() throws {
        let store = makeStore()

        let configuration = try store.set(.hotkey, value: "cmd+shift+Space")

        XCTAssertEqual(configuration.hotkey, "shift+command+space")
        XCTAssertEqual(try store.entry(for: .hotkey).source, .user)
    }

    func testInvalidAndUnknownValuesAreRejected() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "unknown-setting = true\n".write(
            to: store.fileURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try store.validate())
        XCTAssertThrowsError(try store.set(.hotkey, value: "e"))
        XCTAssertThrowsError(try store.set(.showMenuBarIcon, value: "yes"))
    }

    func testXDGConfigHomeMustBeAbsolute() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            AppConfigurationStore.defaultFileURL(
                environment: ["XDG_CONFIG_HOME": "/Volumes/config"],
                homeDirectory: home
            ).path,
            "/Volumes/config/reco/config.toml"
        )
        XCTAssertEqual(
            AppConfigurationStore.defaultFileURL(
                environment: ["XDG_CONFIG_HOME": "relative/config"],
                homeDirectory: home
            ).path,
            "/Users/tester/.config/reco/config.toml"
        )
    }

    private func makeStore() -> AppConfigurationStore {
        AppConfigurationStore(
            fileURL:
                temporaryDirectory
                .appendingPathComponent("reco", isDirectory: true)
                .appendingPathComponent("config.toml")
        )
    }
}
