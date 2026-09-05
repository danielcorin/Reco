@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import CoreGraphics
import CoreMedia
import RecoCore
@preconcurrency import ScreenCaptureKit
import os

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case systemAudioPermissionDenied
    case noInput
    case noSources
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
        case .noSources:
            "Enable a microphone or system audio before recording."
        case .notRecording:
            "No recording is in progress."
        case .recordingFailed(let message):
            "Recording failed: \(message)"
        }
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

@MainActor
final class AudioRecorder {
    var onLevel: (@MainActor (Float) -> Void)?

    private static let logger = Logger(subsystem: "llc.wvlen.Reco", category: "AudioRecorder")
    private var session: RecordingSession?
    private var microphoneCapture: MicrophoneCapture?
    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var streamDelegate: SystemAudioStreamDelegate?

    // Audio devices briefly disappear while Core Audio switches routes (most
    // often when a display, dock, or Bluetooth headset connects). Give the
    // replacement device time to become usable instead of making the user
    // relaunch Reco.
    private static let microphoneRetryDelays: [Duration] = [
        .zero,
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800),
    ]

    static func availableMicrophones() -> [AudioInputDevice] {
        microphoneDevices().map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isBuiltIn: isBuiltIn(device)
            )
        }
    }

    func start(
        microphoneDeviceID: String?,
        capturesMicrophone: Bool,
        capturesSystemAudio: Bool
    ) async throws {
        guard session == nil else {
            throw AudioRecorderError.recordingFailed("A recording is already in progress.")
        }
        guard capturesMicrophone || capturesSystemAudio else {
            throw AudioRecorderError.noSources
        }
        if capturesMicrophone {
            guard await microphoneAccess() else {
                throw AudioRecorderError.permissionDenied
            }
        }
        guard !capturesSystemAudio || CGPreflightScreenCaptureAccess() else {
            throw AudioRecorderError.systemAudioPermissionDenied
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

        do {
            if capturesMicrophone {
                microphoneCapture = try await startMicrophoneCapture(
                    deviceID: microphoneDeviceID,
                    session: session,
                    format: recordingFormat
                )
            }
            if capturesSystemAudio {
                try await startSystemAudioCapture(session: session, format: recordingFormat)
            }
            Self.logger.info(
                "Audio capture started: microphone=\(capturesMicrophone, privacy: .public), systemAudio=\(capturesSystemAudio, privacy: .public)"
            )
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
        await stopMicrophoneCapture()

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
        await stopMicrophoneCapture()

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

    private func startMicrophoneCapture(
        deviceID: String?,
        session: RecordingSession,
        format: AVAudioFormat
    ) async throws -> MicrophoneCapture {
        for (attempt, delay) in Self.microphoneRetryDelays.enumerated() {
            if delay != .zero {
                try await Task.sleep(for: delay)
            }

            guard let device = Self.preferredMicrophone(deviceID: deviceID) else {
                Self.logger.error(
                    "No microphone on attempt \(attempt + 1, privacy: .public)"
                )
                continue
            }

            do {
                let capture = try MicrophoneCapture(
                    device: device,
                    recordingSession: session,
                    outputFormat: format
                ) { [weak self] level in
                    self?.onLevel?(level)
                }
                guard await capture.start() else {
                    await capture.stop()
                    Self.logger.error(
                        "Microphone \(device.localizedName, privacy: .public) did not start on attempt \(attempt + 1, privacy: .public)"
                    )
                    continue
                }

                Self.logger.info(
                    "Microphone capture started with \(device.localizedName, privacy: .public)"
                )
                return capture
            } catch {
                Self.logger.error(
                    "Could not start microphone \(device.localizedName, privacy: .public) on attempt \(attempt + 1, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw AudioRecorderError.noInput
    }

    private func startSystemAudioCapture(
        session: RecordingSession,
        format: AVAudioFormat
    ) async throws {
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
        configuration.sampleRate = Int(format.sampleRate)
        configuration.channelCount = Int(format.channelCount)

        // Reco consumes only the audio output. Keep the unused video side of
        // the stream as inexpensive as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = SystemAudioStreamOutput(session: session)
        let delegate = SystemAudioStreamDelegate(session: session)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        streamOutput = output
        streamDelegate = delegate
        self.stream = stream

        try stream.addStreamOutput(
            output,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )
        try await stream.startCapture()
    }

    /// An explicit choice wins while it remains connected. Automatic mode and
    /// disconnected selections prefer the built-in microphone so Bluetooth
    /// playback stays in A2DP, then fall back to the system default on Macs
    /// without a built-in input.
    private static func preferredMicrophone(deviceID: String?) -> AVCaptureDevice? {
        let devices = microphoneDevices()
        if let deviceID,
            let requested = devices.first(where: { $0.uniqueID == deviceID })
        {
            return requested
        }
        if let builtIn = devices.first(where: { isBuiltIn($0) }) {
            return builtIn
        }

        return AVCaptureDevice.default(for: .audio)
    }

    private static func microphoneDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.sorted { first, second in
            if isBuiltIn(first) != isBuiltIn(second) {
                return isBuiltIn(first)
            }
            return first.localizedName.localizedStandardCompare(second.localizedName)
                == .orderedAscending
        }
    }

    private static func isBuiltIn(_ device: AVCaptureDevice) -> Bool {
        UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    private func stopMicrophoneCapture() async {
        let capture = microphoneCapture
        microphoneCapture = nil
        await capture?.stop()
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

    func writeMicrophone(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        let startTime =
            presentationTime.isValid && presentationSeconds.isFinite
            ? presentationSeconds
            : Self.seconds(forHostTime: AudioGetCurrentHostTime())
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

/// Captures only the selected microphone device. AVAudioEngine uses a hidden
/// per-process aggregate of the default input and output devices on macOS. That
/// aggregate can retain a removed device after docks, displays, or Bluetooth
/// routes change, even when a new engine is created. AVCaptureSession binds to
/// the concrete input device and therefore does not depend on the output route.
private nonisolated final class MicrophoneCapture: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private static let logger = Logger(subsystem: "llc.wvlen.Reco", category: "Microphone")
    private static let controlQueue = DispatchQueue(
        label: "llc.wvlen.Reco.microphone-control",
        qos: .userInitiated
    )

    private let captureSession = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let callbackQueue = DispatchQueue(
        label: "llc.wvlen.Reco.microphone-samples",
        qos: .userInteractive
    )
    private let recordingSession: RecordingSession
    private let onLevel: @MainActor @Sendable (Float) -> Void
    private let loggedFirstBuffer = OSAllocatedUnfairLock(initialState: false)

    init(
        device: AVCaptureDevice,
        recordingSession: RecordingSession,
        outputFormat: AVAudioFormat,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) throws {
        self.recordingSession = recordingSession
        self.onLevel = onLevel
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard captureSession.canAddInput(input) else {
            throw AudioRecorderError.noInput
        }
        captureSession.addInput(input)

        // Ask AVFoundation for the same format used by the track writer. This
        // keeps level metering simple and avoids performing conversion work on
        // the real-time sample callback.
        output.audioSettings = outputFormat.settings
        output.setSampleBufferDelegate(self, queue: callbackQueue)
        guard captureSession.canAddOutput(output) else {
            output.setSampleBufferDelegate(nil, queue: nil)
            throw AudioRecorderError.noInput
        }
        captureSession.addOutput(output)
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            Self.controlQueue.async { [captureSession] in
                captureSession.startRunning()
                continuation.resume(returning: captureSession.isRunning)
            }
        }
    }

    func stop() async {
        output.setSampleBufferDelegate(nil, queue: nil)
        await withCheckedContinuation { continuation in
            Self.controlQueue.async { [captureSession] in
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid,
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
                    "Received first microphone buffer: frames=\(frameCount), sampleRate=\(audioFormat.sampleRate), channels=\(audioFormat.channelCount)"
                )
            }

            recordingSession.writeMicrophone(
                buffer,
                presentationTime: sampleBuffer.presentationTimeStamp
            )
            publishLevel(from: buffer)
        } catch {
            Self.logger.error("Couldn’t copy microphone buffer: \(error.localizedDescription)")
            recordingSession.recordError(error)
        }
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard recordingSession.shouldPublishLevel(),
            let samples = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.0001))
        let normalized = min(max((decibels + 50) / 50, 0), 1)

        Task { @MainActor [onLevel] in
            onLevel(normalized)
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
