import XCTest

@testable import RecoCore

final class ContextTermsTests: XCTestCase {
    func testPicksNamesIdentifiersAndAcronyms() {
        let terms = ContextTerms.extract(
            before: "Today I asked Priya about the FluidAudio upgrade and the JSON parser in gpt-4o_eval.",
            after: ""
        )
        XCTAssertEqual(Set(terms), ["Priya", "FluidAudio", "JSON", "gpt-4o_eval"])
    }

    func testSkipsSentenceOpenersAndOrdinaryWords() {
        let terms = ContextTerms.extract(before: "Then we shipped it. Later we rested.\nAnother line", after: "")
        XCTAssertEqual(terms, [])
    }

    func testNearestToCursorFirstAndDeduplicated() {
        let terms = ContextTerms.extract(
            before: "ask Priya and then Marcus",
            after: " and Marcus or Kenji",
            title: "Notes about Quinn",
            limit: 3
        )
        XCTAssertEqual(terms, ["Marcus", "Priya", "Kenji"])
    }

    func testPossessivesAndShortWords() {
        XCTAssertEqual(ContextTerms.extract(before: "see Priya's notes on an AB test", after: ""), ["Priya"])
    }
}
