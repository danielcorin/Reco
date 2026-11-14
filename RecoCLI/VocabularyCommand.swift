import Foundation
import RecoCore

private struct VocabularyOutput: Encodable {
    var path: String
    var terms: [VocabularyTerm]
}

/// `reco vocab …` edits vocabulary.toml directly, so it works whether or not
/// Reco is running; the app rereads the file before every dictation.
func runVocabularyCommand(arguments: [String], json: Bool) throws {
    let store = VocabularyStore()
    var remaining = arguments[...]
    let action = remaining.popFirst() ?? "list"

    switch action {
    case "path":
        guard remaining.isEmpty else { throw UsageError("vocab path takes no arguments") }
        if json {
            try writeJSON(["path": store.fileURL.path])
        } else {
            print(store.fileURL.path)
        }
        return

    case "list":
        guard remaining.isEmpty else { throw UsageError("vocab list takes no arguments") }

    case "add":
        let (text, heard) = try parseTermArguments(remaining, command: "add")
        try store.update { try $0.add(text, heard: heard, source: .taught) }

    case "remove":
        let (text, heard) = try parseTermArguments(remaining, command: "remove")
        try store.update { vocabulary in
            if heard.isEmpty {
                try vocabulary.remove(text)
            } else {
                for spelling in heard { try vocabulary.removeHeard(spelling, from: text) }
            }
        }

    default:
        throw UsageError("unknown vocab command '\(action)'")
    }

    let vocabulary = try store.load()
    if json {
        try writeJSON(VocabularyOutput(path: store.fileURL.path, terms: vocabulary.terms))
        return
    }
    if vocabulary.isEmpty {
        if action == "list" { print("No vocabulary yet. Add a word with: reco vocab add <word> [--heard <spelling>]") }
        return
    }
    let width = vocabulary.terms.map(\.text.count).max() ?? 0
    for term in vocabulary.terms {
        let name = term.text.padding(toLength: width, withPad: " ", startingAt: 0)
        let heard = term.heard.isEmpty ? "" : "  ← \(term.heard.joined(separator: ", "))"
        print("\(name)  \(term.source.rawValue)\(heard)")
    }
}

private func parseTermArguments(
    _ arguments: ArraySlice<String>, command: String
) throws -> (String, [String]) {
    var remaining = arguments
    var text: String?
    var heard: [String] = []
    while let argument = remaining.popFirst() {
        if argument == "--heard" {
            guard let spelling = remaining.popFirst() else {
                throw UsageError("vocab \(command) --heard requires a spelling")
            }
            heard.append(spelling)
        } else if text == nil {
            text = argument
        } else {
            throw UsageError("vocab \(command) takes one word or phrase; quote phrases with spaces")
        }
    }
    guard let text else { throw UsageError("vocab \(command) requires a word or phrase") }
    return (text, heard)
}
