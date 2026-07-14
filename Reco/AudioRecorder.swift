import Accelerate
import AVFoundation
import os

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case noInput
    case notRecording
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is required."
        case .noInput: "No microphone is available."
        case .notRecording: "No recording is in progress."
        case .recordingFailed(let message): "Recording failed: \(message)"
        }
    }
}

@MainActor
final class AudioRecorder {
    var onLevel: (@MainActor (Float) -> Void)?

    private let engine = AVAudioEngine()
    private var session: RecordingSession?
    private var recordingURL: URL?

    func start() async throws {
        guard await microphoneAccess() else {
            throw AudioRecorderError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInput
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reco-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let session = try RecordingSession(url: url, settings: format.settings)
        self.session = session
        recordingURL = url

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            session.write(buffer)

            guard session.shouldPublishLevel(),
                  let samples = buffer.floatChannelData?[0],
                  buffer.frameLength > 0 else { return }

            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
            let decibels = 20 * log10(max(rms, 0.0001))
            let normalized = min(max((decibels + 50) / 50, 0), 1)

            Task { @MainActor [weak self] in
                self?.onLevel?(normalized)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = session.finish()
            self.session = nil
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }
    }

    func stop() throws -> URL {
        guard let url = recordingURL, let session else {
            throw AudioRecorderError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.session = nil
        recordingURL = nil

        if let writeError = session.finish() {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.recordingFailed(writeError.localizedDescription)
        }

        return url
    }

    private func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

/// Owns the state the tap block mutates. AVAudioEngine delivers tap buffers
/// on an internal audio thread, not the main actor, so every access goes
/// through the lock. `removeTap` does not wait for in-flight callbacks;
/// `finish()` releases the file under the lock, so once it returns no tap
/// callback can reach the file again.
private nonisolated final class RecordingSession: Sendable {
    private struct State {
        var file: AVAudioFile?
        var writeError: Error?
        var bufferCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        state = OSAllocatedUnfairLock(initialState: State(file: file))
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { state in
            guard state.writeError == nil else { return }
            do {
                try state.file?.write(from: buffer)
            } catch {
                state.writeError = error
            }
        }
    }

    /// Level updates are published for every second buffer.
    func shouldPublishLevel() -> Bool {
        state.withLockUnchecked { state in
            state.bufferCount += 1
            return state.bufferCount.isMultiple(of: 2)
        }
    }

    func finish() -> Error? {
        state.withLockUnchecked { state in
            state.file = nil
            return state.writeError
        }
    }
}
