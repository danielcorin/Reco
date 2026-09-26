import Foundation

/// Bridges a CLI connection to the app's existing recording lifecycle.
@MainActor
public final class RecordingServer {
    private var listener: RecordingListener?
    private var activeConnection: RecordingConnection?
    private let startRecording: @MainActor () async throws -> UUID
    private let finishRecording: @MainActor (UUID) async throws -> String
    private let transcribeFile: @MainActor (URL) async throws -> String

    public init(
        startRecording: @escaping @MainActor () async throws -> UUID,
        transcribeFile: @escaping @MainActor (URL) async throws -> String = { _ in
            throw RecordingCommandError("File transcription is unavailable.")
        },
        finishRecording: @escaping @MainActor (UUID) async throws -> String
    ) {
        self.startRecording = startRecording
        self.finishRecording = finishRecording
        self.transcribeFile = transcribeFile
    }

    public func start(at url: URL = RecordingConnection.socketURL) throws {
        guard listener == nil else { return }
        listener = try RecordingListener(url: url) { [weak self] connection in
            Task { @MainActor [weak self] in
                await self?.serve(connection)
            }
        }
    }

    private func serve(_ connection: RecordingConnection) async {
        defer { connection.disconnect() }
        do {
            connection.setReadTimeout(seconds: 5)
            guard let command = try await connection.receiveAsync(String.self) else { return }
            connection.setReadTimeout(seconds: 0)
            switch command {
            case "record":
                try await record(connection)
            case "stop":
                guard let activeConnection else {
                    throw RecordingCommandError("No CLI recording is in progress.")
                }
                activeConnection.stopWaiting()
                try await connection.sendAsync(RecordingReply(event: .stopping))
            case "transcribe":
                connection.setReadTimeout(seconds: 5)
                guard let path = try await connection.receiveAsync(String.self),
                    path.hasPrefix("/")
                else {
                    throw RecordingCommandError("A local audio file path is required.")
                }
                connection.setReadTimeout(seconds: 0)
                let text = try await transcribeFile(URL(fileURLWithPath: path))
                try await connection.sendAsync(RecordingReply(event: .completed, text: text))
            default:
                throw RecordingCommandError("Unknown recording command '\(command)'.")
            }
        } catch {
            try? await connection.sendAsync(RecordingReply(event: .failed, message: error.localizedDescription))
        }
    }

    private func record(_ connection: RecordingConnection) async throws {
        guard activeConnection == nil else {
            throw RecordingCommandError("A CLI recording is already in progress.")
        }
        activeConnection = connection
        defer {
            if activeConnection === connection { activeConnection = nil }
        }
        let id = try await startRecording()
        // Once capture starts, every exit path must finish it, including a
        // CLI that is killed during startup or disconnects before the reply.
        do {
            try await connection.sendAsync(RecordingReply(event: .started))
            _ = try await connection.receiveAsync(String.self)
        } catch {
            // A broken connection is also a stop request.
        }
        activeConnection = nil
        let text = try await finishRecording(id)
        try await connection.sendAsync(RecordingReply(event: .completed, text: text))
    }
}
