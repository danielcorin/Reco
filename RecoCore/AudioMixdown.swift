import AVFoundation
import Foundation

public nonisolated enum AudioMixdown {
    public static func mix(microphoneURL: URL, systemURL: URL, outputURL: URL) throws -> URL {
        let microphone = try AVAudioFile(forReading: microphoneURL)
        let system = try AVAudioFile(forReading: systemURL)
        let format = microphone.processingFormat
        guard format == system.processingFormat,
            format.commonFormat == .pcmFormatFloat32,
            !format.isInterleaved,
            format.channelCount == 1
        else {
            throw AudioMixdownError.incompatibleFormats
        }

        let totalFrames = max(microphone.length, system.length)
        guard totalFrames > 0 else {
            throw AudioMixdownError.noAudio
        }
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        let chunkSize: AVAudioFrameCount = 16_384
        // Reuse the buffers for the entire recording. Memory use stays
        // bounded, without allocating another set for every second of audio.
        guard let microphoneBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
            let systemBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
            let mixedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
            let remainderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
            let microphoneSamples = microphoneBuffer.floatChannelData?[0],
            let systemSamples = systemBuffer.floatChannelData?[0],
            let mixedSamples = mixedBuffer.floatChannelData?[0]
        else {
            throw AudioMixdownError.bufferAllocationFailed
        }
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
            microphoneBuffer.frameLength = 0
            systemBuffer.frameLength = 0
            try readAvailable(from: microphone, into: microphoneBuffer, upTo: requested, scratch: remainderBuffer)
            try readAvailable(from: system, into: systemBuffer, upTo: requested, scratch: remainderBuffer)

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
                    limiterGain = min(requiredGain, limiterGain + (1 - limiterGain) * limiterReleaseCoefficient)
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
        upTo requested: AVAudioFrameCount,
        scratch: AVAudioPCMBuffer
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

        // AVAudioFile can return a partial read before EOF, even for PCM CAF.
        // Fill the chunk before mixing so the remainder of a shorter track
        // does not slide into the next chunk of the longer track.
        while buffer.frameLength < available {
            try file.read(into: scratch, frameCount: available - buffer.frameLength)
            guard scratch.frameLength > 0 else { throw AudioMixdownError.incompleteRead }
            buffer.floatChannelData![0].advanced(by: Int(buffer.frameLength)).update(
                from: scratch.floatChannelData![0], count: Int(scratch.frameLength)
            )
            buffer.frameLength += scratch.frameLength
        }
    }
}

private nonisolated enum AudioMixdownError: LocalizedError {
    case incompatibleFormats
    case noAudio
    case bufferAllocationFailed
    case incompleteRead

    var errorDescription: String? {
        switch self {
        case .incompatibleFormats: "Captured audio tracks have incompatible formats."
        case .noAudio: "No audio was captured."
        case .bufferAllocationFailed: "Couldn’t allocate mixdown buffers."
        case .incompleteRead: "Couldn’t read all of the captured audio."
        }
    }
}
