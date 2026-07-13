import FluidAudio
import Foundation

@MainActor
final class ParakeetTranscriber {
    enum LoadStage: Sendable {
        case downloading
        case preparing
    }

    private var manager: AsrManager?
    private var loadingTask: Task<AsrManager, Error>?

    func prepare(
        progressHandler: @escaping @MainActor @Sendable (Double, LoadStage) -> Void
    ) async throws {
        _ = try await loadManager(progressHandler: progressHandler)
    }

    func transcribe(_ url: URL) async throws -> String {
        let manager = try await loadManager(progressHandler: nil)
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func loadManager(
        progressHandler: (@MainActor @Sendable (Double, LoadStage) -> Void)?
    ) async throws -> AsrManager {
        if let manager { return manager }
        if let loadingTask { return try await loadingTask.value }

        let progress = ModelProgressAccumulator(handler: progressHandler)
        let task = Task<AsrManager, Error> {
            progressHandler?(0, .downloading)
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { update in
                    Task { @MainActor in
                        progress.consume(update)
                    }
                }
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            progressHandler?(1, .preparing)
            return manager
        }
        loadingTask = task

        do {
            let loaded = try await task.value
            manager = loaded
            loadingTask = nil
            return loaded
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

@MainActor
private final class ModelProgressAccumulator {
    private let expectedOperations = 8.0
    private var operationIndex = -1
    private var latestFraction = 0.0
    private let handler: (@MainActor @Sendable (Double, ParakeetTranscriber.LoadStage) -> Void)?

    init(handler: (@MainActor @Sendable (Double, ParakeetTranscriber.LoadStage) -> Void)?) {
        self.handler = handler
    }

    func consume(_ update: DownloadProgress) {
        if case .listing = update.phase {
            operationIndex += 1
        }

        let operation = Double(max(operationIndex, 0))
        let overall = min((operation + update.fractionCompleted) / expectedOperations, 0.98)
        latestFraction = max(latestFraction, overall)

        let stage: ParakeetTranscriber.LoadStage
        switch update.phase {
        case .listing, .downloading:
            stage = .downloading
        case .compiling:
            stage = .preparing
        }
        handler?(latestFraction, stage)
    }
}
