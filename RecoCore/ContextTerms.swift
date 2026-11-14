import Foundation

/// Picks words from the text around the cursor that are worth listening for:
/// names, product and code identifiers, and acronyms. Ordinary words are left
/// out because Parakeet already gets them right and boosting them only invites
/// false replacements.
public enum ContextTerms {
    public static let defaultLimit = 20

    /// Candidate terms, nearest to the cursor first.
    public static func extract(
        before: String,
        after: String,
        title: String? = nil,
        limit: Int = defaultLimit
    ) -> [String] {
        // Nearest first: walk `before` backward from the cursor, then `after`
        // forward, then the window title.
        let ranked =
            candidates(in: before).reversed()
            + candidates(in: after)
            + candidates(in: title ?? "")
        var seen: Set<String> = []
        var result: [String] = []
        for term in ranked where seen.insert(term.lowercased()).inserted {
            result.append(term)
            if result.count == limit { break }
        }
        return result
    }

    static func candidates(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        // The last non-space character before the current word tells a
        // capitalized name apart from a capitalized sentence opener.
        var precedingMark: Character?
        var lastNonSpace: Character?

        func flush() {
            var word = current.trimmingCharacters(in: CharacterSet(charactersIn: "-'’_"))
            current = ""
            if word.hasSuffix("'s") || word.hasSuffix("’s") { word.removeLast(2) }
            if isInteresting(word, sentenceInitial: startsSentence(precedingMark)) {
                result.append(word)
            }
        }

        for character in text {
            if character.isLetter || character.isNumber || "-_'’".contains(character) {
                if current.isEmpty { precedingMark = lastNonSpace }
                current.append(character)
            } else if !current.isEmpty {
                flush()
            }
            if character.isNewline {
                lastNonSpace = "\n"
            } else if !character.isWhitespace {
                lastNonSpace = character
            }
        }
        if !current.isEmpty { flush() }
        return result
    }

    static func isInteresting(_ word: String, sentenceInitial: Bool) -> Bool {
        let base = word
        guard base.count >= 3, base.count <= 40 else { return false }
        let letters = base.filter(\.isLetter)
        guard !letters.isEmpty else { return false }

        let uppercaseCount = letters.filter(\.isUppercase).count
        let hasDigit = base.contains(where: \.isNumber)
        let hasInnerUppercase = letters.dropFirst().contains(where: \.isUppercase)

        if base.contains("_") { return true }
        if hasDigit { return letters.count >= 1 }
        // Acronyms (JSON, NASA) and inner capitals (FluidAudio, iPhone).
        if uppercaseCount == letters.count { return letters.count >= 3 }
        if hasInnerUppercase { return true }
        // A capitalized word mid-sentence is usually a name.
        if letters.first!.isUppercase, !sentenceInitial, base.count >= 4 {
            return !commonCapitalized.contains(base)
        }
        return false
    }

    private static func startsSentence(_ preceding: Character?) -> Bool {
        guard let preceding else { return true }
        return ".!?…\n:•*#>-\"“(".contains(preceding)
    }

    private static let commonCapitalized: Set<String> = [
        "This", "That", "These", "Those", "There", "Then", "When", "What", "Where", "Which",
        "With", "From", "Your", "They", "Their", "About", "After", "Before", "Also", "Just",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
}
