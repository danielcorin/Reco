import AppKit
import Combine
import Foundation
import NaturalLanguage
import RecoCore

/// The menu's view of the vocabulary file plus the in-memory list of recent
/// fixes. The file stays the source of truth: it is reread before every
/// dictation and every change, so edits from the CLI or a text editor are
/// never overwritten. Recent fixes hold word pairs only, never transcripts.
@MainActor
final class PersonalVocabulary: ObservableObject {
    struct RecentFix: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Reco changed a word in a transcript.
            case applied(BoostOrigin)
            /// Reco learned a rule from an edit.
            case learned
            /// An edit changed a fix back, so its rule was removed.
            case forgotten
        }

        let id = UUID()
        let correction: WordCorrection
        let kind: Kind
    }

    @Published private(set) var vocabulary = Vocabulary() {
        didSet { pruneRecentFixes() }
    }
    @Published private(set) var loadError: String?
    @Published private(set) var recentFixes: [RecentFix] = []

    let store: VocabularyStore
    private static let recentLimit = 8

    init(store: VocabularyStore = VocabularyStore()) {
        self.store = store
        reload()
    }

    @discardableResult
    func reload() -> Vocabulary {
        do {
            let loaded = try store.load()
            if vocabulary != loaded { vocabulary = loaded }
            setLoadError(nil)
        } catch {
            setLoadError(error.localizedDescription)
        }
        return vocabulary
    }

    /// The word list for one dictation: the personal vocabulary, then terms
    /// from the text around the cursor that it doesn't already cover.
    func boostTerms(nearby: [String]) -> [BoostTerm] {
        let personal = reload().terms.map {
            BoostTerm(text: $0.text, heard: $0.heard, origin: BoostOrigin($0.source))
        }
        let covered = Set(personal.map { $0.text.lowercased() })
        // A capitalized dictionary word (Notes, Electron) can only match its
        // own inflections, which are usually what was said.
        let context = nearby.filter { term in
            guard !covered.contains(term.lowercased()) else { return false }
            let distinctive = term.dropFirst().contains(where: \.isUppercase) || term.contains(where: \.isNumber)
            return distinctive || !Self.isOrdinaryWord(term.lowercased())
        }.map {
            BoostTerm(text: $0, heard: [], origin: .nearbyText)
        }
        return personal + context
    }

    /// Whether a capitalized first word should stay capitalized mid-sentence:
    /// vocabulary terms and anything the language tagger reads as a name.
    func keepsCapitalized(_ word: String, in transcript: String) -> Bool {
        if vocabulary.terms.contains(where: { $0.text.split(separator: " ").first.map(String.init) == word }) {
            return true
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = transcript
        guard let range = transcript.range(of: word) else { return false }
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    /// A lowercase word the system spelling dictionary knows.
    static func isOrdinaryWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(of: word, startingAt: 0)
        return misspelled.location == NSNotFound
    }

    func recordApplied(_ fixes: [AppliedFix]) {
        for fix in fixes {
            push(RecentFix(correction: fix.correction, kind: .applied(fix.origin)))
        }
    }

    /// Applies what an edit taught: learned swaps become heard spellings, and
    /// learned rules the user changed back are removed. Taught rules are only
    /// changed by the user.
    func learn(from review: CorrectionReview, applied: [AppliedFix]) {
        guard !review.isEmpty else { return }
        var learned: [WordCorrection] = []
        var forgotten: [WordCorrection] = []
        do {
            vocabulary = try store.update { vocabulary in
                for correction in review.learned {
                    // One unusable pair (too long, say) shouldn't block the rest.
                    if (try? vocabulary.add(correction.corrected, heard: [correction.heard], source: .learned)) == true
                    {
                        learned.append(correction)
                    }
                }
                for correction in review.reverted {
                    guard applied.contains(where: { $0.correction == correction && $0.origin == .learned }),
                        (try? vocabulary.removeHeard(correction.heard, from: correction.corrected)) != nil
                    else { continue }
                    forgotten.append(correction)
                }
            }
            setLoadError(nil)
        } catch {
            setLoadError(error.localizedDescription)
            return
        }
        learned.forEach { push(RecentFix(correction: $0, kind: .learned)) }
        forgotten.forEach { push(RecentFix(correction: $0, kind: .forgotten)) }
    }

    /// Whether the menu can offer to remove the rule behind a fix.
    func canRemoveRule(for fix: RecentFix) -> Bool {
        guard fix.kind != .forgotten, fix.kind != .applied(.nearbyText) else { return false }
        return heardRule(for: fix.correction) != nil
    }

    /// Removes the heard spelling that produced a fix, so it won't happen again.
    func removeRule(for fix: RecentFix) {
        guard let term = heardRule(for: fix.correction) else { return }
        mutate { try $0.removeHeard(fix.correction.heard, from: term.text) }
        recentFixes.removeAll { $0.id == fix.id }
    }

    func teach(_ text: String, heard: [String]) throws {
        _ = try store.update { try $0.add(text, heard: heard, source: .taught) }
        reload()
    }

    private func heardRule(for correction: WordCorrection) -> VocabularyTerm? {
        guard let term = vocabulary.term(matching: correction.corrected),
            term.heard.contains(where: { $0.caseInsensitiveCompare(correction.heard) == .orderedSame })
        else { return nil }
        return term
    }

    private func mutate(_ change: (inout Vocabulary) throws -> Void) {
        do {
            vocabulary = try store.update(change)
            setLoadError(nil)
        } catch {
            setLoadError(error.localizedDescription)
        }
    }

    /// Drops fixes whose rule is gone from the file (removed in the menu, with
    /// `reco vocab`, or in an editor), so the list never shows a rule the file
    /// doesn't have. Nearby-text fixes never had a rule, and Removed rows
    /// record the removal itself.
    private func pruneRecentFixes() {
        let kept = recentFixes.filter { fix in
            switch fix.kind {
            case .applied(.nearbyText), .forgotten: true
            case .applied: vocabulary.term(matching: fix.correction.corrected) != nil
            case .learned: heardRule(for: fix.correction) != nil
            }
        }
        if kept != recentFixes { recentFixes = kept }
    }

    private func push(_ fix: RecentFix) {
        recentFixes.insert(fix, at: 0)
        if recentFixes.count > Self.recentLimit { recentFixes.removeLast(recentFixes.count - Self.recentLimit) }
    }

    private func setLoadError(_ message: String?) {
        if loadError != message { loadError = message }
    }
}
