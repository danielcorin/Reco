import Foundation

/// A single word swap: what the model wrote and what it should have written.
public struct WordCorrection: Equatable, Hashable, Sendable, Codable {
    public var heard: String
    public var corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }
}

/// What a later edit to an inserted transcript says about Reco's vocabulary.
public struct CorrectionReview: Equatable, Sendable {
    /// Short, sound-alike swaps worth learning.
    public var learned: [WordCorrection]
    /// Fixes Reco applied that the user changed back; those rules are wrong.
    public var reverted: [WordCorrection]

    public init(learned: [WordCorrection] = [], reverted: [WordCorrection] = []) {
        self.learned = learned
        self.reverted = reverted
    }

    public var isEmpty: Bool { learned.isEmpty && reverted.isEmpty }
}

/// Compares a transcript as Reco inserted it with the same span after the
/// user edited it, and keeps only edits that look like recognition fixes:
/// swaps of one to three words that sound like what they replaced, where the
/// new word is unusual (a name, an identifier, a word the dictionary lacks).
/// Rewrites, additions, deletions, lowercasing, and swaps between ordinary
/// words ("their" → "there", which depends on the sentence) are ignored.
public enum CorrectionLearner {
    static let maxSwapWords = 3
    static let minSimilarity = 0.5

    /// - Parameter applied: fixes Reco made to this transcript, `heard` being
    ///   the model's word and `corrected` what Reco inserted.
    ///   - isOrdinaryWord: whether a lowercase word is a common dictionary word.
    public static func review(
        inserted: String,
        edited: String,
        applied: [WordCorrection] = [],
        isOrdinaryWord: (String) -> Bool = { _ in false }
    ) -> CorrectionReview {
        let old = words(in: inserted)
        let new = words(in: edited)
        guard !old.isEmpty, !new.isEmpty, old != new else { return CorrectionReview() }

        let hunks = substitutions(old, new)
        let changedWords = hunks.reduce(0) { $0 + max($1.old.count, $1.new.count) }
        // More than half the words changed: that's a rewrite, not a fix.
        guard changedWords * 2 <= old.count else { return CorrectionReview() }

        var review = CorrectionReview()
        for hunk in hunks {
            guard (1...maxSwapWords).contains(hunk.old.count),
                (1...maxSwapWords).contains(hunk.new.count)
            else { continue }
            let heard = hunk.old.joined(separator: " ")
            let corrected = hunk.new.joined(separator: " ")

            if let fix = applied.first(where: {
                $0.corrected.caseInsensitiveCompare(heard) == .orderedSame
                    && $0.heard.caseInsensitiveCompare(corrected) == .orderedSame
            }) {
                review.reverted.append(fix)
                continue
            }
            guard isPlausibleFix(heard: heard, corrected: corrected),
                !isOrdinary(hunk.new, replacing: hunk.old, isOrdinaryWord: isOrdinaryWord)
            else { continue }
            let correction = WordCorrection(heard: heard, corrected: corrected)
            if !review.learned.contains(correction) { review.learned.append(correction) }
        }
        return review
    }

    /// Dictionary words, which a vocabulary rule would rewrite everywhere even
    /// though the right choice depends on the sentence. A capital the edit
    /// introduced ("turn" → "Tarn") marks a name, not an ordinary word; one
    /// both sides share ("Their" → "There" opening a sentence) doesn't.
    static func isOrdinary(_ new: [String], replacing old: [String], isOrdinaryWord: (String) -> Bool) -> Bool {
        new.enumerated().allSatisfy { index, word in
            let letters = word.filter(\.isLetter)
            if word.contains(where: \.isNumber) || letters.dropFirst().contains(where: \.isUppercase) {
                return false
            }
            if letters.first?.isUppercase == true {
                let previous = index < old.count ? old[index] : ""
                guard previous.first?.isUppercase == true else { return false }
            }
            return isOrdinaryWord(word.lowercased())
        }
    }

    static func isPlausibleFix(heard: String, corrected: String) -> Bool {
        guard corrected.count <= 40, corrected.contains(where: \.isLetter) else { return false }
        if heard.caseInsensitiveCompare(corrected) == .orderedSame {
            // Case-only edits are often sentence restructuring; only inner
            // capitals (iPhone, FluidAudio) clearly describe the word itself.
            return corrected.filter(\.isLetter).dropFirst().contains(where: \.isUppercase)
                && heard != corrected
        }
        let a = heard.lowercased().filter(\.isLetter)
        let b = corrected.lowercased().filter(\.isLetter)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return similarity(a, b) >= minSimilarity || soundex(a) == soundex(b)
    }

    /// Words with surrounding punctuation removed; inner apostrophes,
    /// hyphens, and dots stay.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let word = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return word.isEmpty ? nil : word
        }
    }

    struct Hunk: Equatable {
        var old: [String]
        var new: [String]
    }

    /// Replaced runs between the longest common subsequence of two word lists.
    static func substitutions(_ old: [String], _ new: [String]) -> [Hunk] {
        let n = old.count
        let m = new.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var hunks: [Hunk] = []
        var pending = Hunk(old: [], new: [])
        var i = 0
        var j = 0
        func closePending() {
            if !pending.old.isEmpty || !pending.new.isEmpty { hunks.append(pending) }
            pending = Hunk(old: [], new: [])
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                closePending()
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                pending.new.append(new[j])
                j += 1
            } else {
                pending.old.append(old[i])
                i += 1
            }
        }
        closePending()
        return hunks
    }

    /// 1 minus normalized Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a)
        let b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// American Soundex: a coarse "sounds like" key.
    static func soundex(_ word: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = Array(word.lowercased().filter { $0.isASCII && $0.isLetter })
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased()
        var last = codes[first]
        for letter in letters.dropFirst() {
            let code = codes[letter]
            if let code, code != last { result.append(code) }
            if letter != "h", letter != "w" { last = code }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}

/// Finds the span that replaced an inserted transcript, by locating the text
/// that was on either side of it when it was inserted.
public enum EditRecovery {
    public static let anchorLength = 24

    /// - Parameters:
    ///   - region: Current text of the field around the insertion point.
    ///   - beforeAnchor: Text that ended right before the insertion, or empty
    ///     when the insertion began the field.
    ///   - afterAnchor: Text that began right after it, or empty when the
    ///     insertion ended the field.
    ///   - regionStartsField / regionEndsField: whether `region` reaches the
    ///     field's start or end, which an empty anchor requires.
    public static func editedSpan(
        in region: String,
        beforeAnchor: String,
        afterAnchor: String,
        regionStartsField: Bool,
        regionEndsField: Bool,
        maxLength: Int
    ) -> String? {
        let start: String.Index
        if beforeAnchor.isEmpty {
            guard regionStartsField else { return nil }
            start = region.startIndex
        } else {
            guard let found = region.range(of: beforeAnchor) else { return nil }
            start = found.upperBound
        }

        let end: String.Index
        if afterAnchor.isEmpty {
            guard regionEndsField else { return nil }
            end = region.endIndex
        } else {
            guard let found = region.range(of: afterAnchor, range: start..<region.endIndex) else { return nil }
            end = found.lowerBound
        }

        let span = String(region[start..<end])
        return span.count <= maxLength ? span : nil
    }

    /// The anchor to remember on each side of an insertion.
    public static func anchors(for context: InsertionContext) -> (before: String, after: String) {
        (String(context.before.suffix(anchorLength)), String(context.after.prefix(anchorLength)))
    }
}

/// Applies word replacements to a transcript in order, each to the next
/// whole-word, case-insensitive match after the previous one. Used to rebuild
/// a rescored transcript when some of the rescorer's replacements are vetoed.
public enum ReplacementApplier {
    public static func apply(_ replacements: [WordCorrection], to transcript: String) -> String {
        var result = transcript
        var searchStart = result.startIndex
        for replacement in replacements {
            let pattern =
                "(?<![\\p{L}\\p{N}'’-])" + NSRegularExpression.escapedPattern(for: replacement.heard)
                + "(?![\\p{L}\\p{N}'’-])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: result, range: NSRange(searchStart..<result.endIndex, in: result)),
                let range = Range(match.range, in: result)
            else { continue }
            let offset = result.distance(from: result.startIndex, to: range.lowerBound)
            result.replaceSubrange(range, with: replacement.corrected)
            searchStart = result.index(result.startIndex, offsetBy: offset + replacement.corrected.count)
        }
        return result
    }
}
