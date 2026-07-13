import AVFoundation
import Accelerate

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
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var writeError: Error?

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
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        writeError = nil
        audioFile = file
        recordingURL = url

        var levelSampleCounter = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                self.writeError = error
            }

            levelSampleCounter += 1
            guard levelSampleCounter.isMultiple(of: 2),
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
            audioFile = nil
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }
    }

    func stop() throws -> URL {
        guard let url = recordingURL else {
            throw AudioRecorderError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        recordingURL = nil

        if let writeError {
            self.writeError = nil
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
