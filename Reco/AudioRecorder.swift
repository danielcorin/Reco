@preconcurrency import AVFoundation
import Accelerate
import CoreGraphics
import CoreMedia
@preconcurrency import ScreenCaptureKit
import os

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case systemAudioPermissionDenied
    case noInput
    case notRecording
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is required."
        case .systemAudioPermissionDenied:
            "Screen & System Audio Recording access is required."
        case .noInput:
            "No microphone is available."
        case .notRecording:
            "No recording is in progress."
        case .recordingFailed(let message):
            "Recording failed: \(message)"
        }
    }
}

@MainActor
final class AudioRecorder {
    var onLevel: (@MainActor (Float) -> Void)?

    private static let logger = Logger(subsystem: "llc.wvlen.Reco", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private var session: RecordingSession?
    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var streamDelegate: SystemAudioStreamDelegate?
    private var inputTapInstalled = false

    func start() async throws {
        guard session == nil else {
            throw AudioRecorderError.recordingFailed("A recording is already in progress.")
        }
        guard await microphoneAccess() else {
            throw AudioRecorderError.permissionDenied
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw AudioRecorderError.systemAudioPermissionDenied
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInput
        }
        guard
            let recordingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioRecorderError.recordingFailed("Couldn’t create the recording format.")
        }

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reco-\(UUID().uuidString)")
        let session = try RecordingSession(baseURL: baseURL, format: recordingFormat)
        self.session = session

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, time in
            session.writeMicrophone(buffer, hostTime: time.hostTime)

            guard session.shouldPublishLevel(),
                let samples = buffer.floatChannelData?[0],
                buffer.frameLength > 0
            else { return }

            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
            let decibels = 20 * log10(max(rms, 0.0001))
            let normalized = min(max((decibels + 50) / 50, 0), 1)

            Task { @MainActor [weak self] in
                self?.onLevel?(normalized)
            }
        }
        inputTapInstalled = true

        do {
            engine.prepare()
            try engine.start()

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let mainDisplayID = CGMainDisplayID()
            guard
                let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                    ?? content.displays.first
            else {
                throw AudioRecorderError.recordingFailed("No display is available for system audio capture.")
            }

            let currentApp = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == currentApp }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(recordingFormat.sampleRate)
            configuration.channelCount = Int(recordingFormat.channelCount)

            // Reco consumes only the audio output. Keep the unused video side of
            // the stream as inexpensive as possible.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let output = SystemAudioStreamOutput(session: session)
            let delegate = SystemAudioStreamDelegate(session: session)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            self.streamOutput = output
            self.streamDelegate = delegate
            self.stream = stream

            try stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: .global(qos: .userInteractive)
            )
            try await stream.startCapture()
            Self.logger.info("Microphone and system-audio capture started")
        } catch {
            await discardCurrentRecording()
            if let recorderError = error as? AudioRecorderError {
                throw recorderError
            }
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }
    }

    func stop() async throws -> URL {
        guard let session else {
            throw AudioRecorderError.notRecording
        }

        session.beginStopping()
        stopMicrophoneCapture()

        let streamToStop = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if let streamToStop {
            do {
                try await streamToStop.stopCapture()
            } catch {
                session.recordError(error)
            }
        }

        self.session = nil
        let result = session.finish()
        Self.logger.info(
            "Capture stopped: microphone buffers=\(result.microphoneBufferCount), system buffers=\(result.systemBufferCount)"
        )
        if let error = result.error {
            result.removeAllFiles()
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }

        do {
            let outputURL = try await Task.detached(priority: .userInitiated) {
                try AudioMixdown.mix(
                    microphoneURL: result.microphoneURL,
                    systemURL: result.systemURL,
                    outputURL: result.outputURL
                )
            }.value
            result.removeSourceFiles()
            return outputURL
        } catch {
            result.removeAllFiles()
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }
    }

    private func discardCurrentRecording() async {
        session?.beginStopping()
        stopMicrophoneCapture()

        let streamToStop = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if let streamToStop {
            try? await streamToStop.stopCapture()
        }

        let result = session?.finish()
        session = nil
        result?.removeAllFiles()
    }

    private func stopMicrophoneCapture() {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine.stop()
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

private nonisolated struct RecordingResult: Sendable {
    let microphoneURL: URL
    let systemURL: URL
    let outputURL: URL
    let error: Error?
    let microphoneBufferCount: Int
    let systemBufferCount: Int

    func removeSourceFiles() {
        try? FileManager.default.removeItem(at: microphoneURL)
        try? FileManager.default.removeItem(at: systemURL)
    }

    func removeAllFiles() {
        removeSourceFiles()
        try? FileManager.default.removeItem(at: outputURL)
    }
}

/// Owns all state mutated by the microphone and ScreenCaptureKit callback
/// threads. Each source is converted to the same 16 kHz mono format and written
/// to a time-aligned temporary track. The tracks are mixed after capture stops.
private nonisolated final class RecordingSession: Sendable {
    private struct State {
        var microphoneWriter: TimedTrackWriter?
        var systemWriter: TimedTrackWriter?
        var writeError: Error?
        var bufferCount = 0
        var microphoneBufferCount = 0
        var systemBufferCount = 0
        var isStopping = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let microphoneURL: URL
    private let systemURL: URL
    private let outputURL: URL
    private let baseHostTimeSeconds: TimeInterval

    init(baseURL: URL, format: AVAudioFormat) throws {
        microphoneURL = baseURL.appendingPathExtension("microphone.caf")
        systemURL = baseURL.appendingPathExtension("system.caf")
        outputURL = baseURL.appendingPathExtension("caf")
        baseHostTimeSeconds = Self.seconds(forHostTime: AudioGetCurrentHostTime())

        let microphoneWriter = try TimedTrackWriter(url: microphoneURL, format: format)
        let systemWriter = try TimedTrackWriter(url: systemURL, format: format)
        state = OSAllocatedUnfairLock(
            initialState: State(
                microphoneWriter: microphoneWriter,
                systemWriter: systemWriter
            ))
    }

    func writeMicrophone(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let startTime =
            hostTime == 0
            ? Self.seconds(forHostTime: AudioGetCurrentHostTime())
            : Self.seconds(forHostTime: hostTime)
        write(buffer, source: .microphone, startTime: startTime)
    }

    func writeSystem(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        let startTime =
            presentationTime.isValid && presentationSeconds.isFinite
            ? presentationSeconds
            : Self.seconds(forHostTime: AudioGetCurrentHostTime())
        write(buffer, source: .system, startTime: startTime)
    }

    func recordError(_ error: Error) {
        state.withLockUnchecked { state in
            guard !state.isStopping, state.writeError == nil else { return }
            state.writeError = error
        }
    }

    func beginStopping() {
        state.withLockUnchecked { state in
            state.isStopping = true
        }
    }

    /// Level updates are published for every second microphone buffer.
    func shouldPublishLevel() -> Bool {
        state.withLockUnchecked { state in
            state.bufferCount += 1
            return state.bufferCount.isMultiple(of: 2)
        }
    }

    func finish() -> RecordingResult {
        let result = state.withLockUnchecked { state in
            state.isStopping = true
            state.microphoneWriter = nil
            state.systemWriter = nil
            return (
                error: state.writeError,
                microphoneBufferCount: state.microphoneBufferCount,
                systemBufferCount: state.systemBufferCount
            )
        }
        return RecordingResult(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            outputURL: outputURL,
            error: result.error,
            microphoneBufferCount: result.microphoneBufferCount,
            systemBufferCount: result.systemBufferCount
        )
    }

    private enum Source {
        case microphone
        case system
    }

    private func write(_ buffer: AVAudioPCMBuffer, source: Source, startTime: TimeInterval) {
        state.withLockUnchecked { state in
            guard !state.isStopping, state.writeError == nil else { return }
            do {
                let relativeStart = max(0, startTime - baseHostTimeSeconds)
                switch source {
                case .microphone:
                    try state.microphoneWriter?.write(buffer, firstBufferStart: relativeStart)
                    state.microphoneBufferCount += 1
                case .system:
                    try state.systemWriter?.write(buffer, firstBufferStart: relativeStart)
                    state.systemBufferCount += 1
                }
            } catch {
                state.writeError = error
            }
        }
    }

    private static func seconds(forHostTime hostTime: UInt64) -> TimeInterval {
        TimeInterval(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
    }
}

/// Converts one source to the common recording format and inserts leading
/// silence so its first sample stays aligned to the session host clock.
private nonisolated final class TimedTrackWriter {
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var wroteFirstBuffer = false

    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func write(_ buffer: AVAudioPCMBuffer, firstBufferStart: TimeInterval) throws {
        guard let file else { return }
        let converted = try convert(buffer)
        guard converted.frameLength > 0 else { return }

        if !wroteFirstBuffer {
            let leadingFrames = AVAudioFramePosition(
                (firstBufferStart * format.sampleRate).rounded()
            )
            if leadingFrames > 0 {
                try writeSilence(frameCount: leadingFrames, to: file)
            }
            wroteFirstBuffer = true
        }

        try file.write(from: converted)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format {
            return buffer
        }

        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            throw AudioRecorderError.recordingFailed("Couldn’t convert captured audio.")
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, (Double(buffer.frameLength) * ratio).rounded(.up) + 1)
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioRecorderError.recordingFailed("Couldn’t allocate an audio buffer.")
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }

    private func writeSilence(frameCount: AVAudioFramePosition, to file: AVAudioFile) throws {
        var remaining = frameCount
        let chunkSize: AVAudioFrameCount = 16_384
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkSize)))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw AudioRecorderError.recordingFailed("Couldn’t allocate a silence buffer.")
            }
            silence.frameLength = frames
            if let samples = silence.floatChannelData?[0] {
                samples.initialize(repeating: 0, count: Int(frames))
            }
            try file.write(from: silence)
            remaining -= AVAudioFramePosition(frames)
        }
    }
}

private nonisolated final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let logger = Logger(subsystem: "llc.wvlen.Reco", category: "SystemAudio")
    private let session: RecordingSession
    private let loggedFirstBuffer = OSAllocatedUnfairLock(initialState: false)

    init(session: RecordingSession) {
        self.session = session
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio,
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let description = sampleBuffer.formatDescription
        else {
            return
        }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: description)

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        do {
            try sampleBuffer.copyPCMData(
                fromRange: 0..<frameCount,
                into: buffer.mutableAudioBufferList
            )
            let shouldLog = loggedFirstBuffer.withLock { logged in
                guard !logged else { return false }
                logged = true
                return true
            }
            if shouldLog {
                Self.logger.info(
                    "Received first system-audio buffer: frames=\(frameCount), sampleRate=\(audioFormat.sampleRate), channels=\(audioFormat.channelCount)"
                )
            }
            session.writeSystem(buffer, presentationTime: sampleBuffer.presentationTimeStamp)
        } catch {
            Self.logger.error("Couldn’t copy system-audio buffer: \(error.localizedDescription)")
            session.recordError(error)
        }
    }
}

private nonisolated final class SystemAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let session: RecordingSession

    init(session: RecordingSession) {
        self.session = session
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger(subsystem: "llc.wvlen.Reco", category: "SystemAudio")
            .error("System-audio stream stopped: \(error.localizedDescription)")
        session.recordError(error)
    }
}

private nonisolated enum AudioMixdown {
    static func mix(microphoneURL: URL, systemURL: URL, outputURL: URL) throws -> URL {
        let microphone = try AVAudioFile(forReading: microphoneURL)
        let system = try AVAudioFile(forReading: systemURL)
        let format = microphone.processingFormat
        guard format == system.processingFormat,
            format.commonFormat == .pcmFormatFloat32,
            !format.isInterleaved,
            format.channelCount == 1
        else {
            throw AudioRecorderError.recordingFailed("Captured audio tracks have incompatible formats.")
        }

        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        let totalFrames = max(microphone.length, system.length)
        guard totalFrames > 0 else {
            throw AudioRecorderError.recordingFailed("No audio was captured.")
        }
        let chunkSize: AVAudioFrameCount = 16_384
        let limiterCeiling: Float = 0.95
        let limiterReleaseSeconds = 0.15
        let limiterReleaseCoefficient = Float(
            1 - exp(-1 / (format.sampleRate * limiterReleaseSeconds))
        )
        var limiterGain: Float = 1
        var framesWritten: AVAudioFramePosition = 0

        while framesWritten < totalFrames {
            let requested = AVAudioFrameCount(
                min(AVAudioFramePosition(chunkSize), totalFrames - framesWritten)
            )
            guard let microphoneBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested),
                let systemBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested),
                let mixedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested),
                let microphoneSamples = microphoneBuffer.floatChannelData?[0],
                let systemSamples = systemBuffer.floatChannelData?[0],
                let mixedSamples = mixedBuffer.floatChannelData?[0]
            else {
                throw AudioRecorderError.recordingFailed("Couldn’t allocate mixdown buffers.")
            }

            microphoneBuffer.frameLength = 0
            systemBuffer.frameLength = 0
            try readAvailable(from: microphone, into: microphoneBuffer, upTo: requested)
            try readAvailable(from: system, into: systemBuffer, upTo: requested)

            let microphoneFrames = Int(microphoneBuffer.frameLength)
            let systemFrames = Int(systemBuffer.frameLength)
            let mixedFrames = max(microphoneFrames, systemFrames)
            guard mixedFrames > 0 else { break }

            for index in 0..<mixedFrames {
                let microphoneSample = index < microphoneFrames ? microphoneSamples[index] : 0
                let systemSample = index < systemFrames ? systemSamples[index] : 0
                let combinedSample = microphoneSample + systemSample
                let magnitude = abs(combinedSample)
                let requiredGain =
                    magnitude > limiterCeiling
                    ? limiterCeiling / magnitude
                    : 1

                // Attenuate peaks immediately, then restore unity gain slowly
                // to avoid clipping without audible pumping between sources.
                if requiredGain < limiterGain {
                    limiterGain = requiredGain
                } else {
                    limiterGain += (1 - limiterGain) * limiterReleaseCoefficient
                }
                mixedSamples[index] = combinedSample * limiterGain
            }

            mixedBuffer.frameLength = AVAudioFrameCount(mixedFrames)
            try output.write(from: mixedBuffer)
            framesWritten += AVAudioFramePosition(mixedFrames)
        }

        return outputURL
    }

    /// AVAudioFile throws a generic Objective-C error if it is asked to read
    /// after EOF. The two capture tracks rarely end on the same frame, so read
    /// only what remains and let mixdown treat the shorter track as silence.
    private static func readAvailable(
        from file: AVAudioFile,
        into buffer: AVAudioPCMBuffer,
        upTo requested: AVAudioFrameCount
    ) throws {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else {
            buffer.frameLength = 0
            return
        }

        let available = AVAudioFrameCount(
            min(remaining, AVAudioFramePosition(requested))
        )
        try file.read(into: buffer, frameCount: available)
    }
}
