import Foundation
import TOML

/// Where a vocabulary term came from.
public enum VocabularySource: String, Codable, CaseIterable, Sendable {
    /// Added explicitly, from the menu or `reco vocab add`.
    case taught
    /// Picked up from a correction made after a dictation.
    case learned
}

/// A word or phrase Reco listens for, with the spellings the model wrote
/// instead. Stored as plain text, so it works with any recognition model.
public struct VocabularyTerm: Codable, Equatable, Sendable {
    public var text: String
    public var heard: [String]
    public var source: VocabularySource

    public init(text: String, heard: [String] = [], source: VocabularySource = .taught) {
        self.text = text
        self.heard = heard
        self.source = source
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case text, heard, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown vocabulary key '\(unknown)'."
                ))
        }
        text = try container.decode(String.self, forKey: AnyKey("text"))
        heard = try container.decodeIfPresent([String].self, forKey: AnyKey("heard")) ?? []
        source = try container.decodeIfPresent(VocabularySource.self, forKey: AnyKey("source")) ?? .taught
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if !heard.isEmpty { try container.encode(heard, forKey: .heard) }
        try container.encode(source, forKey: .source)
    }
}

public enum VocabularyError: LocalizedError, Equatable, Sendable {
    case invalidText(String, reason: String)
    case unknownTerm(String)
    case invalidFile(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidText(let text, let reason):
            "Invalid vocabulary text '\(text)': \(reason)"
        case .unknownTerm(let text):
            "'\(text)' isn’t in the vocabulary."
        case .invalidFile(let path, let reason):
            "Invalid vocabulary at \(path): \(reason)"
        }
    }
}

/// The personal vocabulary: terms in the order they were added.
public struct Vocabulary: Equatable, Sendable {
    public private(set) var terms: [VocabularyTerm]

    public static let maxLength = 64

    public init(terms: [VocabularyTerm] = []) {
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func term(matching text: String) -> VocabularyTerm? {
        terms.first { $0.text.caseInsensitiveCompare(text) == .orderedSame }
    }

    /// Adds a term, or merges into the existing one with the same text. A
    /// heard spelling belongs to one term only, so it moves from any other
    /// term. Teaching a learned term makes it taught; learning never demotes.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func add(
        _ text: String,
        heard: [String] = [],
        source: VocabularySource = .taught
    ) throws -> Bool {
        let text = try Self.validated(text)
        let heard = try heard.map(Self.validated).filter { $0 != text }
        let before = terms

        var emptied: Set<String> = []
        for spelling in heard {
            for index in terms.indices
            where terms[index].text.caseInsensitiveCompare(text) != .orderedSame {
                let count = terms[index].heard.count
                terms[index].heard.removeAll { $0.caseInsensitiveCompare(spelling) == .orderedSame }
                if count > 0, terms[index].heard.isEmpty { emptied.insert(terms[index].text) }
            }
        }
        // A learned term that just lost its last heard spelling has nothing left to do.
        terms.removeAll { $0.source == .learned && emptied.contains($0.text) }

        if let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            if source == .taught {
                terms[index].text = text
                terms[index].source = .taught
            }
            for spelling in heard
            where !terms[index].heard.contains(where: { $0.caseInsensitiveCompare(spelling) == .orderedSame }) {
                terms[index].heard.append(spelling)
            }
        } else {
            terms.append(VocabularyTerm(text: text, heard: Self.deduplicated(heard), source: source))
        }
        return terms != before
    }

    /// Removes a whole term.
    public mutating func remove(_ text: String) throws {
        guard let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else {
            throw VocabularyError.unknownTerm(text)
        }
        terms.remove(at: index)
    }

    /// Removes one heard spelling from a term. A learned term exists only for
    /// its heard spellings, so it is removed along with its last one.
    public mutating func removeHeard(_ spelling: String, from text: String) throws {
        guard let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else {
            throw VocabularyError.unknownTerm(text)
        }
        let count = terms[index].heard.count
        terms[index].heard.removeAll { $0.caseInsensitiveCompare(spelling) == .orderedSame }
        guard terms[index].heard.count != count else {
            throw VocabularyError.unknownTerm("\(spelling) → \(text)")
        }
        if terms[index].source == .learned, terms[index].heard.isEmpty {
            terms.remove(at: index)
        }
    }

    static func validated(_ raw: String) throws -> String {
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else {
            throw VocabularyError.invalidText(raw, reason: "it is empty")
        }
        guard text.count <= maxLength else {
            throw VocabularyError.invalidText(raw, reason: "use at most \(maxLength) characters")
        }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VocabularyError.invalidText(raw, reason: "it contains control characters")
        }
        return text
    }

    private static func deduplicated(_ spellings: [String]) -> [String] {
        var seen: Set<String> = []
        return spellings.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Reads and writes `$XDG_CONFIG_HOME/reco/vocabulary.toml`, beside
/// `config.toml`, so the vocabulary travels with the rest of the user's
/// configuration. The app and the CLI both write it; each write rereads the
/// file first, so neither overwrites the other's changes.
public struct VocabularyStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        AppConfigurationStore.defaultFileURL(environment: environment, homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("vocabulary.toml")
    }

    /// A missing file means an empty vocabulary.
    public func load() throws -> Vocabulary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Vocabulary() }
        do {
            let file = try TOMLDecoder().decode(VocabularyFile.self, from: Data(contentsOf: fileURL))
            var vocabulary = Vocabulary()
            for term in file.term {
                try vocabulary.add(term.text, heard: term.heard, source: term.source)
            }
            return vocabulary
        } catch {
            throw VocabularyError.invalidFile(path: fileURL.path, reason: String(describing: error))
        }
    }

    /// Rereads the file, applies `change`, and writes the result.
    @discardableResult
    public func update(_ change: (inout Vocabulary) throws -> Void) throws -> Vocabulary {
        var vocabulary = try load()
        let original = vocabulary
        try change(&vocabulary)
        if vocabulary != original { try save(vocabulary) }
        return vocabulary
    }

    /// Writes a file with only the explanatory header and an example, for
    /// someone opening the vocabulary to edit by hand.
    public func writeTemplate() throws {
        try prepareDirectory()
        let example = """
            # Example:
            # [[term]]
            # text = "Reco"
            # heard = ["Rico", "Rekko"]
            # source = "taught"

            """
        try write(Data((Self.header + example).utf8))
    }

    public func save(_ vocabulary: Vocabulary) throws {
        let fileManager = FileManager.default
        if vocabulary.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        try prepareDirectory()
        var data = Data(Self.header.utf8)
        data.append(try TOMLEncoder().encode(VocabularyFile(term: vocabulary.terms)))
        try write(data)
    }

    private static let header = """
        # Reco vocabulary
        # Words Reco listens for. `heard` lists spellings the model wrote instead;
        # Reco replaces them only when the audio supports the term.
        # source = "taught" (you added it) or "learned" (picked up from your edits).
        # Manage with `reco vocab`, or edit this file directly.

        """

    private func prepareDirectory() throws {
        try AppConfigurationStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("config.toml")
        ).prepareDirectory()
    }

    private func write(_ data: Data) throws {
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private struct VocabularyFile: Codable {
    var term: [VocabularyTerm]

    init(term: [VocabularyTerm]) {
        self.term = term
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = container.allKeys.map(\.stringValue).first(where: { $0 != "term" }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown vocabulary key '\(unknown)'; use [[term]] tables."
                ))
        }
        term = try container.decodeIfPresent([VocabularyTerm].self, forKey: AnyKey("term")) ?? []
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Vocabulary {
    /// Rewrites whole-word, case-insensitive matches of each term with the
    /// term's own casing ("parakeet" → "Parakeet"). The acoustic rescorer
    /// leaves words that already match a term apart from case untouched.
    public static func applyingCase(
        of terms: [String],
        to text: String
    ) -> (text: String, fixes: [WordCorrection]) {
        var result = text
        var fixes: [WordCorrection] = []
        for term in terms.sorted(by: { $0.count > $1.count })
        where term.contains(where: \.isUppercase) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let found = String(result[range])
                guard found != term else { continue }
                result.replaceSubrange(range, with: term)
                let fix = WordCorrection(heard: found, corrected: term)
                if !fixes.contains(fix) { fixes.append(fix) }
            }
        }
        return (result, fixes)
    }
}
