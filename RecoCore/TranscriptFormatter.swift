import Foundation

/// The text on either side of the cursor (or selection) where a transcript
/// will land. Either side may be a short window rather than the whole field.
public struct InsertionContext: Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }
}

/// Fits a transcript to the text around the cursor: lowercases the first word
/// when dictating mid-sentence, drops a trailing period when the sentence
/// continues, and adds the spaces the surrounding text needs. Parakeet always
/// writes a fresh, capitalized, period-terminated sentence, so without context
/// the transcript is returned unchanged.
public enum TranscriptFormatter {
    public static func fit(
        _ text: String,
        into context: InsertionContext?,
        keepsCapitalized: (String) -> Bool = { _ in false }
    ) -> String {
        guard let context, !text.isEmpty else { return text }
        var result = text

        if position(after: context.before) == .midSentence {
            result = lowercasingFirstWord(of: result, context: context, keepsCapitalized: keepsCapitalized)
        }
        if continuesSentence(context.after) {
            result = droppingTrailingPeriod(from: result)
        }
        if let first = result.first, needsLeadingSpace(before: context.before, first: first) {
            result = " " + result
        }
        if let last = result.last, needsTrailingSpace(after: context.after, last: last) {
            result += " "
        }
        return result
    }

    enum Position: Equatable {
        case sentenceStart
        case midSentence
        /// After a colon, an opening quote, or an opening bracket, where either
        /// case is reasonable.
        case ambiguous
    }

    static func position(after before: String) -> Position {
        if before.isEmpty { return .sentenceStart }
        let trailingWhitespace = before.reversed().prefix(while: \.isWhitespace)
        if trailingWhitespace.contains(where: \.isNewline) { return .sentenceStart }

        let trimmed = String(before.dropLast(trailingWhitespace.count))
        guard let last = trimmed.last else { return .sentenceStart }

        let lastLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
        if isListMarker(lastLine) { return .sentenceStart }

        if "([{".contains(last), trailingWhitespace.isEmpty { return .ambiguous }
        if openingQuotes.contains(last), trailingWhitespace.isEmpty {
            let beforeQuote = trimmed.dropLast().last
            if beforeQuote == nil || beforeQuote!.isWhitespace { return .ambiguous }
        }

        let core = trimmed.reversed().drop(while: { closingMarks.contains($0) })
        guard let terminal = core.first else { return .sentenceStart }
        if sentenceTerminators.contains(terminal) { return .sentenceStart }
        if terminal == ":" { return .ambiguous }
        return .midSentence
    }

    static func lowercasingFirstWord(
        of text: String,
        context: InsertionContext,
        keepsCapitalized: (String) -> Bool
    ) -> String {
        let leading = text.prefix(while: { !$0.isLetter && !$0.isNumber })
        let rest = text.dropFirst(leading.count)
        let word = String(rest.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }))
        guard let first = word.first, first.isUppercase else { return text }

        let letters = word.filter(\.isLetter)
        if letters == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return text }
        // Acronyms and inner capitals (NASA, McDonald) are deliberate.
        if letters.dropFirst().contains(where: \.isUppercase) { return text }
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
        if keepsCapitalized(bare) || alwaysCapitalized.contains(bare) { return text }
        if appearsCapitalizedMidSentence(bare, in: context.before + " " + context.after) { return text }

        return String(leading) + first.lowercased() + String(rest.dropFirst())
    }

    static func continuesSentence(_ after: String) -> Bool {
        guard let next = after.first(where: { !$0.isWhitespace || $0.isNewline }) else { return false }
        if next.isNewline { return false }
        if next.isLetter { return next.isLowercase }
        if next.isNumber { return true }
        return ",.;:!?)]}”’".contains(next)
    }

    static func droppingTrailingPeriod(from text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        let lastWord = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? text
        let stem = lastWord.dropLast()
        // "e.g." and "etc." keep their periods.
        if stem.contains(".") || abbreviations.contains(stem.lowercased()) { return text }
        return String(text.dropLast())
    }

    static func needsLeadingSpace(before: String, first: Character) -> Bool {
        guard let last = before.last, !last.isWhitespace else { return false }
        if ",.;:!?)]}”’%".contains(first) { return false }
        if "([{“‘/-@#_$".contains(last) { return false }
        if last == "\"" || last == "'" {
            // An opening quote hugs the next word; a closing one is followed by a space.
            let beforeQuote = before.dropLast().last
            return !(beforeQuote == nil || beforeQuote!.isWhitespace)
        }
        return true
    }

    static func needsTrailingSpace(after: String, last: Character) -> Bool {
        guard let next = after.first, !next.isWhitespace else { return false }
        if "([{“-/".contains(last) { return false }
        return next.isLetter || next.isNumber || "([{“".contains(next)
    }

    static func appearsCapitalizedMidSentence(_ word: String, in text: String) -> Bool {
        guard word.count > 1 else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: [], range: searchRange) {
            defer { searchRange = found.upperBound..<text.endIndex }
            let isWordStart =
                found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter
            let isWordEnd = found.upperBound == text.endIndex || !text[found.upperBound].isLetter
            guard isWordStart, isWordEnd else { continue }
            let preceding = text[..<found.lowerBound]
            if position(after: String(preceding)) == .midSentence { return true }
        }
        return false
    }

    private static func isListMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if ["-", "*", "+", "•", ">", "#", "##", "###", "- [ ]", "- [x]", "* [ ]"].contains(trimmed) { return true }
        if let last = trimmed.last, last == "." || last == ")" {
            return trimmed.dropLast().allSatisfy(\.isNumber) && trimmed.count > 1
        }
        return false
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "*", "_"]
    private static let openingQuotes: Set<Character> = ["\"", "'", "“", "‘"]
    private static let abbreviations: Set<String> = [
        "etc", "vs", "mr", "mrs", "ms", "dr", "st", "inc", "ltd", "jr", "sr", "co",
    ]
    private static let alwaysCapitalized: Set<String> = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "June", "July", "August", "September",
        "October", "November", "December",
    ]
}
