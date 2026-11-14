import FluidAudio
import Foundation
import RecoCore

/// Where a term in one dictation's word list came from.
nonisolated enum BoostOrigin: String, Sendable {
    case taught
    case learned
    /// Taken from the text around the cursor for this dictation only.
    case nearbyText

    init(_ source: VocabularySource) {
        switch source {
        case .taught: self = .taught
        case .learned: self = .learned
        }
    }
}

nonisolated struct BoostTerm: Sendable, Equatable {
    var text: String
    var heard: [String]
    var origin: BoostOrigin

    /// Words from nearby text were never confirmed by the user, so they need
    /// a near-exact spelling: "fluid audio" → "FluidAudio" (0.91) passes,
    /// "note" → "Notes" (0.8) doesn't.
    var minSimilarity: Float? {
        origin == .nearbyText ? VocabularyBooster.nearbyTextMinSimilarity : nil
    }
}

/// A fix Reco made to one transcript, kept so it can be reviewed or undone.
nonisolated struct AppliedFix: Sendable, Equatable {
    var correction: WordCorrection
    var origin: BoostOrigin
}

/// One dictation's word list, tokenized and ready to rescore a transcript.
/// Built while the user is still speaking, so it costs nothing after release.
nonisolated struct BoostPlan: Sendable {
    fileprivate let vocabulary: CustomVocabularyContext
    fileprivate let rescorer: VocabularyRescorer
    let terms: [BoostTerm]
}

/// Biases transcripts toward the user's vocabulary with FluidAudio's CTC
/// keyword rescoring: a second, small model (Parakeet CTC 110M) scores the
/// same audio, and a word is swapped for a vocabulary term only when that
/// model's acoustic evidence supports the term.
///
/// The similarity floor is strict (0.8). At FluidAudio's default (0.5),
/// "Puerto Rico" became "Puerto Reco" for a vocabulary containing "Reco";
/// at 0.8 that stops, and replacements come mostly from `heard` spellings,
/// which grow as Reco learns from corrections.
actor VocabularyBooster {
    static let minSimilarity: Float = 0.8
    static let nearbyTextMinSimilarity: Float = 0.9
    /// FluidAudio's "acoustic rescue" proposes a term wherever the audio
    /// loosely resembles it, regardless of `minSimilarity`. With terms taken
    /// from nearby text it replaced whole phrases with words never said
    /// ("When I put something" → "Ghostty", "recorded speech" → "Notes"), so
    /// it stays off: a term needs a close spelling or a `heard` spelling.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    private var spotter: CtcKeywordSpotter?
    private var tokenizer: CtcTokenizer?
    private var loading: Task<(CtcKeywordSpotter, CtcTokenizer), Error>?

    var isReady: Bool { spotter != nil }

    /// Downloads (once, into FluidAudio's shared model cache) and loads the
    /// CTC model.
    func prepare() async throws {
        _ = try await loadModels()
    }

    /// Tokenizes the terms and builds a rescorer, or nil when there is
    /// nothing to boost or the model is not loaded yet. Never waits for a
    /// download, so a slow first launch can't delay dictation.
    func plan(for terms: [BoostTerm]) async -> BoostPlan? {
        guard !terms.isEmpty, let spotter, let tokenizer else { return nil }
        let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let tokens = tokenizer.encode(term.text)
            guard !tokens.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                aliases: term.heard.isEmpty ? nil : term.heard,
                ctcTokenIds: tokens,
                minSimilarity: term.minSimilarity
            )
        }
        guard !vocabularyTerms.isEmpty else { return nil }
        let vocabulary = CustomVocabularyContext(
            terms: vocabularyTerms,
            minSimilarity: Self.minSimilarity
        )
        do {
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocabulary,
                config: Self.rescorerConfig,
                ctcModelDirectory: CtcModels.defaultCacheDirectory()
            )
            return BoostPlan(vocabulary: vocabulary, rescorer: rescorer, terms: terms)
        } catch {
            NSLog("Reco: couldn’t prepare vocabulary boosting: %@", error.localizedDescription)
            return nil
        }
    }

    /// CTC log-probabilities for the recording. Runs in parallel with
    /// Parakeet, which reads the same file.
    func scoreAudio(_ url: URL, plan: BoostPlan) async throws -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard let spotter else { return nil }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: plan.vocabulary
        )
    }

    /// - Parameter isOrdinaryWord: whether a lowercase word is a common
    ///   dictionary word. A real word is replaced only through one of the
    ///   term's `heard` spellings: "note" never becomes "Notes" just because
    ///   the spellings are close.
    nonisolated func rescore(
        _ transcript: ParakeetTranscript,
        scores: CtcKeywordSpotter.SpotKeywordsResult,
        plan: BoostPlan,
        isOrdinaryWord: (String) -> Bool
    ) -> (text: String, fixes: [AppliedFix]) {
        guard !transcript.tokenTimings.isEmpty, !scores.logProbs.isEmpty else {
            return (transcript.text, [])
        }
        let output = plan.rescorer.ctcTokenRescore(
            transcript: transcript.text,
            tokenTimings: transcript.tokenTimings,
            logProbs: scores.logProbs,
            frameDuration: scores.frameDuration,
            cbw: ContextBiasingConstants.rescorerConfig(forVocabSize: plan.terms.count).cbw,
            minSimilarity: Self.minSimilarity
        )
        guard output.wasModified else { return (transcript.text, []) }

        var vetoed = false
        let fixes = output.replacements.compactMap { replacement -> AppliedFix? in
            guard replacement.shouldReplace, let word = replacement.replacementWord,
                word != replacement.originalWord
            else { return nil }
            let term = plan.terms.first { $0.text.caseInsensitiveCompare(word) == .orderedSame }
            let original = replacement.originalWord
            let isHeardSpelling =
                term?.heard.contains { $0.caseInsensitiveCompare(original) == .orderedSame } ?? false
            if !isHeardSpelling, !original.contains(" "),
                isOrdinaryWord(original.lowercased().trimmingCharacters(in: .punctuationCharacters))
            {
                vetoed = true
                return nil
            }
            return AppliedFix(
                correction: WordCorrection(heard: original, corrected: word),
                origin: term?.origin ?? .nearbyText
            )
        }
        let text = vetoed ? ReplacementApplier.apply(fixes.map(\.correction), to: transcript.text) : output.text
        return (text, fixes)
    }

    private func loadModels() async throws -> (CtcKeywordSpotter, CtcTokenizer) {
        if let spotter, let tokenizer { return (spotter, tokenizer) }
        if let loading { return try await loading.value }
        let task = Task<(CtcKeywordSpotter, CtcTokenizer), Error> {
            let models = try await CtcModels.downloadAndLoad()
            let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory())
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            return (spotter, tokenizer)
        }
        loading = task
        do {
            let loaded = try await task.value
            spotter = loaded.0
            tokenizer = loaded.1
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }
}
