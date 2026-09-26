import Darwin
import Foundation
import RecoCore

private enum ExitCode: Int32 {
    case failure = 1
    case usage = 2
}

private struct PathOutput: Codable {
    var path: String
}

private struct EntriesOutput: Codable {
    var entries: [AppConfigurationEntry]
}

private struct ValidationOutput: Codable {
    var path: String
    var valid: Bool
}

private struct Command {
    var action: String
    var arguments: [String]
    var json: Bool
    var isRecordingCommand = false

    init(_ rawArguments: [String]) throws {
        json = rawArguments.contains("--json")
        let positional = rawArguments.filter { $0 != "--json" }
        if let first = positional.first, ["record", "stop", "transcribe"].contains(first) {
            isRecordingCommand = true
            action = first
            arguments = Array(positional.dropFirst())
            return
        }
        guard positional.first == "config" else {
            if positional.isEmpty || ["help", "--help", "-h"].contains(positional.first ?? "") {
                action = "help"
                arguments = []
                return
            }
            throw UsageError("unknown command '\(positional.first ?? "")'")
        }
        action = positional.dropFirst().first ?? "help"
        arguments = Array(positional.dropFirst(2))
    }
}

private func parseKey(_ value: String) throws -> AppConfigurationKey {
    guard let key = AppConfigurationKey(rawValue: value) else {
        throw AppConfigurationError.invalidKey(value)
    }
    return key
}

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func notifyApp() {
    DistributedNotificationCenter.default().postNotificationName(
        AppConfigurationStore.changeNotification,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

private func printEntry(_ entry: AppConfigurationEntry, json: Bool) throws {
    if json {
        try writeJSON(entry)
    } else {
        print(entry.value.displayValue)
    }
}

private func run(_ command: Command) throws {
    if command.isRecordingCommand {
        if command.arguments == ["--help"] || command.arguments == ["-h"] {
            print(help)
            return
        }
        if command.action == "transcribe" {
            try runFileTranscriptionCommand(arguments: command.arguments, json: command.json)
        } else {
            try runRecordingCommand(command.action, arguments: command.arguments, json: command.json)
        }
        return
    }
    let store = AppConfigurationStore()

    switch command.action {
    case "help", "--help", "-h":
        print(help)

    case "path":
        guard command.arguments.isEmpty else { throw UsageError("config path takes no arguments") }
        if command.json {
            try writeJSON(PathOutput(path: store.fileURL.path))
        } else {
            print(store.fileURL.path)
        }

    case "get":
        guard command.arguments.count == 1 else { throw UsageError("config get requires one key") }
        try printEntry(try store.entry(for: parseKey(command.arguments[0])), json: command.json)

    case "set":
        guard command.arguments.count == 2 else {
            throw UsageError("config set requires a key and value")
        }
        let key = try parseKey(command.arguments[0])
        _ = try store.set(key, value: command.arguments[1])
        notifyApp()
        try printEntry(try store.entry(for: key), json: command.json)

    case "unset":
        guard command.arguments.count == 1 else { throw UsageError("config unset requires one key") }
        let key = try parseKey(command.arguments[0])
        _ = try store.unset(key)
        notifyApp()
        try printEntry(try store.entry(for: key), json: command.json)

    case "list":
        let all = command.arguments == ["--all"]
        guard command.arguments.isEmpty || all else {
            throw UsageError("config list accepts only --all")
        }
        let entries = try store.entries(changesOnly: !all)
        if command.json {
            try writeJSON(EntriesOutput(entries: entries))
        } else {
            for entry in entries {
                print("\(entry.key.rawValue) = \(entry.value.displayValue)\t# \(entry.source.rawValue)")
            }
        }

    case "validate":
        guard command.arguments.count <= 1 else {
            throw UsageError("config validate accepts at most one path")
        }
        let validationStore =
            command.arguments.first.map {
                AppConfigurationStore(fileURL: URL(fileURLWithPath: $0))
            } ?? store
        try validationStore.validate()
        if command.json {
            try writeJSON(ValidationOutput(path: validationStore.fileURL.path, valid: true))
        } else {
            print("Configuration is valid: \(validationStore.fileURL.path)")
        }

    case "reload":
        guard command.arguments.isEmpty else { throw UsageError("config reload takes no arguments") }
        try store.validate()
        notifyApp()
        if command.json {
            try writeJSON(ValidationOutput(path: store.fileURL.path, valid: true))
        } else {
            print("Reload requested.")
        }

    default:
        throw UsageError("unknown config command '\(command.action)'")
    }
}

struct UsageError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private let help = """
    Reco CLI

    Usage:
      reco record [--duration <seconds>] [--json]  Record and print the transcript
      reco stop [--json]                         Stop the active CLI recording
      reco transcribe <audio-file> [--json]      Transcribe an existing audio file
      reco config path [--json]                 Print the configuration file path
      reco config get <key> [--json]            Print one effective value
      reco config set <key> <value> [--json]    Persist an override
      reco config unset <key> [--json]          Restore a key's default
      reco config list [--all] [--json]         List changed or all effective values
      reco config validate [path] [--json]      Validate TOML and configuration values
      reco config reload [--json]               Ask a running Reco to reload
      reco help                                  Show this help

    Recording uses the running Reco app and its selected audio sources.
    Without --duration, record until Ctrl-C, SIGINT, SIGTERM, SIGHUP, or reco stop.
    The duration starts after capture begins. Progress goes to stderr; the final
    transcript goes to stdout (or {"text": "..."} with --json), without pasting.
    reco stop acknowledges the stop; the original record command returns the text.
    transcribe reads a local audio file through the running Reco app and prints
    its transcript without changing the file, clipboard, or focused app.

    Keys:
      hotkey                Global shortcut, for example control+e
      show-menu-bar-icon    true or false

    Reco reads $XDG_CONFIG_HOME/reco/config.toml, falling back to
    ~/.config/reco/config.toml. Only values changed from defaults are persisted.
    """

do {
    try run(Command(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    FileHandle.standardError.write(Data("reco: \(error.localizedDescription)\n\n\(help)\n".utf8))
    Darwin.exit(ExitCode.usage.rawValue)
} catch {
    FileHandle.standardError.write(Data("reco: \(error.localizedDescription)\n".utf8))
    Darwin.exit(ExitCode.failure.rawValue)
}
