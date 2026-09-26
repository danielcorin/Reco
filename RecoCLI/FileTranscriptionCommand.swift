import Foundation
import RecoCore

private struct FileTranscriptOutput: Encodable {
    let text: String
}

func runFileTranscriptionCommand(arguments: [String], json: Bool) throws {
    guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
        throw UsageError("transcribe requires one audio file path")
    }
    let url = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
    guard values?.isRegularFile == true, values?.isReadable == true else {
        throw RecordingCommandError("Audio file is missing or unreadable: \(url.path)")
    }

    // The app may not have macOS Files & Folders access to the source location
    // (notably Downloads), even when this CLI can read it. Stage a private copy
    // in the user's temporary directory for the app to open.
    let stagedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Reco-import-\(UUID().uuidString)")
        .appendingPathExtension(url.pathExtension)
    try FileManager.default.copyItem(at: url, to: stagedURL)
    defer { try? FileManager.default.removeItem(at: stagedURL) }

    let connection = try RecordingConnection.connect()
    defer { connection.disconnect() }
    connection.setReadTimeout(seconds: 30)
    try connection.send("transcribe")
    try connection.send(stagedURL.path)
    connection.setReadTimeout(seconds: 0)
    guard let reply = try connection.receive(RecordingReply.self) else {
        throw RecordingCommandError("Reco disconnected before returning the transcript.")
    }
    guard reply.event == .completed, let text = reply.text else {
        throw RecordingCommandError(reply.message ?? "Reco did not return a transcript.")
    }
    if json {
        try writeJSON(FileTranscriptOutput(text: text))
    } else {
        print(text)
    }
}
