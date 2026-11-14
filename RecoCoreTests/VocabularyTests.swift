import XCTest

@testable import RecoCore

final class VocabularyTests: XCTestCase {
    private var directory: URL!
    private var store: VocabularyStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = VocabularyStore(fileURL: directory.appendingPathComponent("reco/vocabulary.toml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultPathSitsBesideConfig() {
        let url = VocabularyStore.defaultFileURL(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: URL(fileURLWithPath: "/Users/someone")
        )
        XCTAssertEqual(url.path, "/tmp/xdg/reco/vocabulary.toml")
        let fallback = VocabularyStore.defaultFileURL(
            environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(fallback.path, "/Users/someone/.config/reco/vocabulary.toml")
    }

    func testAddMergesHeardSpellingsCaseInsensitively() throws {
        var vocabulary = Vocabulary()
        XCTAssertTrue(try vocabulary.add("Reco", heard: ["Rico"]))
        XCTAssertTrue(try vocabulary.add("reco", heard: ["rico", "Reko"], source: .learned))
        XCTAssertFalse(try vocabulary.add("Reco", heard: ["REKO"], source: .learned))
        XCTAssertEqual(vocabulary.terms, [VocabularyTerm(text: "Reco", heard: ["Rico", "Reko"], source: .taught)])
    }

    func testTeachingPromotesLearnedTermAndTakesItsCasing() throws {
        var vocabulary = Vocabulary()
        try vocabulary.add("fluidaudio", heard: ["fluid audio"], source: .learned)
        try vocabulary.add("FluidAudio")
        XCTAssertEqual(vocabulary.terms, [VocabularyTerm(text: "FluidAudio", heard: ["fluid audio"], source: .taught)])
    }

    func testHeardSpellingMovesToNewestTerm() throws {
        var vocabulary = Vocabulary()
        try vocabulary.add("Rekko", heard: ["eco"], source: .learned)
        try vocabulary.add("Reco", heard: ["eco"])
        // The learned term lost its only spelling, so it is gone.
        XCTAssertEqual(vocabulary.terms, [VocabularyTerm(text: "Reco", heard: ["eco"])])
    }

    func testRemoveHeardDropsEmptyLearnedTermButKeepsTaughtOne() throws {
        var vocabulary = Vocabulary()
        try vocabulary.add("Reco", heard: ["Rico"])
        try vocabulary.add("Tarn", heard: ["turn"], source: .learned)
        try vocabulary.removeHeard("rico", from: "reco")
        try vocabulary.removeHeard("turn", from: "Tarn")
        XCTAssertEqual(vocabulary.terms, [VocabularyTerm(text: "Reco")])
        XCTAssertThrowsError(try vocabulary.removeHeard("x", from: "Reco"))
        XCTAssertThrowsError(try vocabulary.remove("Nope"))
    }

    func testValidationNormalizesWhitespaceAndRejectsBadText() throws {
        var vocabulary = Vocabulary()
        try vocabulary.add("  Pull   Request ")
        XCTAssertEqual(vocabulary.terms.first?.text, "Pull Request")
        XCTAssertThrowsError(try vocabulary.add("   "))
        XCTAssertThrowsError(try vocabulary.add(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try vocabulary.add("bad\u{7}"))
    }

    func testRoundTripsThroughTOMLAndRemovesEmptyFile() throws {
        XCTAssertEqual(try store.load(), Vocabulary())
        try store.update { vocabulary in
            try vocabulary.add("Reco", heard: ["Rico", "eco"])
            try vocabulary.add("FluidAudio", source: .learned)
        }
        let contents = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[[term]]"), contents)
        XCTAssertTrue(contents.hasPrefix("# Reco vocabulary"))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let loaded = try store.load()
        XCTAssertEqual(
            loaded.terms,
            [
                VocabularyTerm(text: "Reco", heard: ["Rico", "eco"]),
                VocabularyTerm(text: "FluidAudio", source: .learned),
            ])

        try store.update { vocabulary in
            try vocabulary.remove("Reco")
            try vocabulary.remove("FluidAudio")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testReadsHandWrittenFileWithDefaults() throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [[term]]
        text = "Parakeet"

        [[term]]
        text = "Reco"
        heard = ["Rico"]
        source = "learned"
        """.write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try store.load().terms,
            [
                VocabularyTerm(text: "Parakeet"),
                VocabularyTerm(text: "Reco", heard: ["Rico"], source: .learned),
            ])
    }

    func testRejectsUnknownKeysAndSources() throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for contents in [
            "[[term]]\ntext = \"Reco\"\nweight = 2\n",
            "[[term]]\ntext = \"Reco\"\nsource = \"guessed\"\n",
            "words = [\"Reco\"]\n",
        ] {
            try contents.write(to: store.fileURL, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.load(), contents)
        }
    }
}

final class VocabularyCasingTests: XCTestCase {
    func testAppliesTermCasingToWholeWords() {
        let result = Vocabulary.applyingCase(
            of: ["Parakeet", "FluidAudio", "pull request", "Pull Request Bot"],
            to: "The parakeet model and fluidaudio. Parakeets aren't matched; pull request bot is."
        )
        XCTAssertEqual(
            result.text, "The Parakeet model and FluidAudio. Parakeets aren't matched; Pull Request Bot is.")
        XCTAssertEqual(
            result.fixes,
            [
                WordCorrection(heard: "pull request bot", corrected: "Pull Request Bot"),
                WordCorrection(heard: "fluidaudio", corrected: "FluidAudio"),
                WordCorrection(heard: "parakeet", corrected: "Parakeet"),
            ])
    }
}
