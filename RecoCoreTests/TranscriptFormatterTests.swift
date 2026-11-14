import XCTest

@testable import RecoCore

final class TranscriptFormatterTests: XCTestCase {
    private func fit(_ text: String, _ before: String, _ after: String = "", keep: Set<String> = []) -> String {
        TranscriptFormatter.fit(
            text,
            into: InsertionContext(before: before, after: after),
            keepsCapitalized: { keep.contains($0) }
        )
    }

    func testWithoutContextLeavesTranscriptUnchanged() {
        XCTAssertEqual(TranscriptFormatter.fit("Hello there.", into: nil), "Hello there.")
    }

    func testEmptyFieldKeepsSentence() {
        XCTAssertEqual(fit("Hello there.", ""), "Hello there.")
    }

    func testMidSentenceLowercasesAndSpaces() {
        XCTAssertEqual(fit("The build passed.", "I checked and"), " the build passed.")
        XCTAssertEqual(fit("The build passed.", "I checked and "), "the build passed.")
    }

    func testAfterSentenceEndKeepsCapitalAndAddsSpace() {
        XCTAssertEqual(fit("It works.", "Done."), " It works.")
        XCTAssertEqual(fit("It works.", "Really?\" "), "It works.")
        XCTAssertEqual(fit("It works.", "(Done.)"), " It works.")
    }

    func testNewlineAndListMarkersStartSentences() {
        XCTAssertEqual(fit("Buy milk.", "Groceries\n"), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "Groceries\n- "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "1. "), "Buy milk.")
    }

    func testKeepsDeliberateCapitals() {
        XCTAssertEqual(fit("I think so.", "and then"), " I think so.")
        XCTAssertEqual(fit("I'm in.", "and then"), " I'm in.")
        XCTAssertEqual(fit("NASA launched.", "and then"), " NASA launched.")
        XCTAssertEqual(fit("McDonald called.", "and then"), " McDonald called.")
        XCTAssertEqual(fit("Monday works.", "maybe"), " Monday works.")
        XCTAssertEqual(fit("Reco is fast.", "I think", keep: ["Reco"]), " Reco is fast.")
    }

    func testKeepsWordCapitalizedElsewhereInContext() {
        XCTAssertEqual(fit("Dan agreed.", "I asked Dan, and"), " Dan agreed.")
        // Capitalized only at a sentence start says nothing about the word.
        XCTAssertEqual(fit("Then it failed.", "Then we shipped. and"), " then it failed.")
    }

    func testColonAndOpeningQuoteLeaveCaseAlone() {
        XCTAssertEqual(fit("Ship it.", "The plan:"), " Ship it.")
        XCTAssertEqual(fit("Ship it.", "She said \""), "Ship it.")
    }

    func testDropsPeriodWhenSentenceContinues() {
        XCTAssertEqual(fit("The tests", "Run", " and ship."), " the tests")
        XCTAssertEqual(fit("The tests.", "Run", " and ship."), " the tests")
        XCTAssertEqual(fit("The tests.", "Run", "and ship."), " the tests ")
        XCTAssertEqual(fit("The tests.", "Run", ", then ship."), " the tests")
        XCTAssertEqual(fit("Done.", "It's", " Next one."), " done.")
    }

    func testKeepsAbbreviationsAndQuestions() {
        XCTAssertEqual(fit("Apples, pears, etc.", "Buy", " and more"), " apples, pears, etc.")
        XCTAssertEqual(fit("Is it?", "Well", " maybe"), " is it?")
    }

    func testSpacingAroundPunctuationAndBrackets() {
        XCTAssertEqual(fit("Like this.", "("), "Like this.")
        XCTAssertEqual(fit("Like this.", "see ("), "Like this.")
        XCTAssertEqual(fit("Like this", "(see", ")"), " like this")
        XCTAssertEqual(fit("Hello", "path/"), "hello")
        XCTAssertEqual(fit("Word", "\"quoted\""), " word")
    }

    func testCursorBeforeWordAddsTrailingSpace() {
        XCTAssertEqual(fit("Quick.", "", "brown fox"), "Quick ")
        XCTAssertEqual(fit("Quick.", "", "\nNext"), "Quick.")
    }
}
