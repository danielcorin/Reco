import AVFoundation
import XCTest

@testable import RecoCore

final class AudioMixdownTests: XCTestCase {
    private var directory: URL!
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUnequalTracksPreserveTheTailAcrossBufferBoundaries() throws {
        let microphone = [Float](repeating: 0.2, count: 17_401)
        let system = [Float](repeating: 0.3, count: 34_001)
        let samples = try mix(microphone: microphone, system: system)

        XCTAssertEqual(samples.count, system.count)
        XCTAssertTrue(samples[..<microphone.count].allSatisfy { abs($0 - 0.5) < 0.00001 })
        XCTAssertTrue(samples[microphone.count...].allSatisfy { abs($0 - 0.3) < 0.00001 })

        XCTAssertEqual(try mix(microphone: system, system: microphone), samples)
    }

    func testSingleSourceIsPreservedWhenOtherTrackIsEmpty() throws {
        let source = (0..<20_000).map { Float(sin(Double($0) * 0.1)) * 0.4 }

        XCTAssertEqual(try mix(microphone: source, system: []), source)
        XCTAssertEqual(try mix(microphone: [], system: source), source)
    }

    func testLimiterProtectsPositiveAndNegativePeaksAcrossChunks() throws {
        let loud = (0..<34_001).map { $0.isMultiple(of: 2) ? Float(0.8) : Float(-0.8) }
        let samples = try mix(microphone: loud, system: loud)

        XCTAssertEqual(samples.count, loud.count)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.95001 })
        XCTAssertGreaterThan(samples[0], 0)
        XCTAssertLessThan(samples[1], 0)
    }

    func testEmptyRecordingFailsWithoutCreatingOutput() throws {
        XCTAssertThrowsError(try mix(microphone: [], system: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mixed.caf").path))
    }

    private func mix(microphone: [Float], system: [Float]) throws -> [Float] {
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system.caf")
        let outputURL = directory.appendingPathComponent("mixed.caf")
        try write(microphone, to: microphoneURL)
        try write(system, to: systemURL)
        _ = try AudioMixdown.mix(microphoneURL: microphoneURL, systemURL: systemURL, outputURL: outputURL)

        let file = try AVAudioFile(forReading: outputURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else {
                XCTFail("Reading stopped before the end of the mixed recording.")
                break
            }
            samples.append(
                contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard !samples.isEmpty else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
