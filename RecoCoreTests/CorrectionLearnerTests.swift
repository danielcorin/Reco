import XCTest

@testable import RecoCore

final class CorrectionLearnerTests: XCTestCase {
    func testLearnsSoundAlikeSwap() {
        let review = CorrectionLearner.review(
            inserted: "I opened Rico and dictated a note.",
            edited: "I opened Reco and dictated a note."
        )
        XCTAssertEqual(review.learned, [WordCorrection(heard: "Rico", corrected: "Reco")])
        XCTAssertEqual(review.reverted, [])
    }

    func testLearnsMultiWordSwap() {
        let review = CorrectionLearner.review(
            inserted: "We use fluid audio for transcription.",
            edited: "We use FluidAudio for transcription."
        )
        XCTAssertEqual(review.learned, [WordCorrection(heard: "fluid audio", corrected: "FluidAudio")])
    }

    func testIgnoresRewritesAdditionsAndUnrelatedSwaps() {
        XCTAssertTrue(
            CorrectionLearner.review(inserted: "Send the report today.", edited: "Send the report tomorrow.")
                .learned.isEmpty)
        XCTAssertTrue(
            CorrectionLearner.review(inserted: "Send the report.", edited: "Please send the full report.")
                .learned.isEmpty)
        XCTAssertTrue(
            CorrectionLearner.review(inserted: "Ship it now.", edited: "Let's wait until Monday instead.")
                .learned.isEmpty)
    }

    func testIgnoresPunctuationAndSentenceCaseEdits() {
        XCTAssertTrue(
            CorrectionLearner.review(inserted: "it works so we shipped", edited: "It works. So we shipped.")
                .isEmpty)
    }

    func testSkipsSwapsBetweenOrdinaryWords() {
        let ordinary: Set<String> = ["their", "there", "the", "is", "car", "over"]
        let review = CorrectionLearner.review(
            inserted: "Their car is over the hill.",
            edited: "There car is over the hill.",
            isOrdinaryWord: { ordinary.contains($0.lowercased()) }
        )
        XCTAssertTrue(review.learned.isEmpty)
        // An unusual replacement is still learned.
        XCTAssertEqual(
            CorrectionLearner.review(
                inserted: "Ask the turn team.", edited: "Ask the Tarn team.",
                isOrdinaryWord: { ordinary.contains($0.lowercased()) || $0 == "turn" }
            ).learned,
            [WordCorrection(heard: "turn", corrected: "Tarn")])
    }

    func testLearnsInnerCapitals() {
        XCTAssertEqual(
            CorrectionLearner.review(inserted: "Charge the iphone first.", edited: "Charge the iPhone first.")
                .learned,
            [WordCorrection(heard: "iphone", corrected: "iPhone")])
    }

    func testChangingAFixBackRevertsIt() {
        let applied = [WordCorrection(heard: "Rico", corrected: "Reco")]
        let review = CorrectionLearner.review(
            inserted: "We flew to Puerto Reco.",
            edited: "We flew to Puerto Rico.",
            applied: applied
        )
        XCTAssertEqual(review.reverted, applied)
        XCTAssertEqual(review.learned, [])
    }

    func testSimilarityAndSoundex() {
        XCTAssertEqual(CorrectionLearner.similarity("reco", "reco"), 1)
        XCTAssertEqual(CorrectionLearner.similarity("rico", "reco"), 0.75)
        XCTAssertEqual(CorrectionLearner.soundex("Robert"), "R163")
        XCTAssertEqual(CorrectionLearner.soundex("Rupert"), "R163")
        XCTAssertEqual(CorrectionLearner.soundex("their"), CorrectionLearner.soundex("there"))
    }

    func testEditedSpanBetweenAnchors() {
        let region = "Notes: I opened Reco today. Next item"
        XCTAssertEqual(
            EditRecovery.editedSpan(
                in: region, beforeAnchor: "Notes:", afterAnchor: " Next",
                regionStartsField: false, regionEndsField: false, maxLength: 200),
            " I opened Reco today.")
        XCTAssertNil(
            EditRecovery.editedSpan(
                in: region, beforeAnchor: "", afterAnchor: " Next",
                regionStartsField: false, regionEndsField: false, maxLength: 200))
        XCTAssertEqual(
            EditRecovery.editedSpan(
                in: "Hello there", beforeAnchor: "", afterAnchor: "",
                regionStartsField: true, regionEndsField: true, maxLength: 200),
            "Hello there")
        XCTAssertNil(
            EditRecovery.editedSpan(
                in: region, beforeAnchor: "missing", afterAnchor: "",
                regionStartsField: false, regionEndsField: true, maxLength: 200))
        XCTAssertNil(
            EditRecovery.editedSpan(
                in: region, beforeAnchor: "Notes:", afterAnchor: " Next",
                regionStartsField: false, regionEndsField: false, maxLength: 5))
    }
}

final class ReplacementApplierTests: XCTestCase {
    func testAppliesInOrderToWholeWords() {
        XCTAssertEqual(
            ReplacementApplier.apply(
                [
                    WordCorrection(heard: "eco", corrected: "Reco"),
                    WordCorrection(heard: "fluid audio", corrected: "FluidAudio"),
                    WordCorrection(heard: "eco", corrected: "Reco"),
                ],
                to: "I opened eco, an eco-friendly fluid audio app. Eco again."
            ),
            "I opened Reco, an eco-friendly FluidAudio app. Reco again.")
    }

    func testSkipsMissingWords() {
        XCTAssertEqual(
            ReplacementApplier.apply([WordCorrection(heard: "missing", corrected: "X")], to: "Nothing here."),
            "Nothing here.")
    }
}
