import Foundation
import XCTest

@testable import RecoCore

@MainActor
final class RecordingServerTests: XCTestCase {
    private func socketURL() -> URL {
        let directory = URL(fileURLWithPath: "/tmp/reco-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("recording.sock")
    }

    private func connect(_ url: URL, command: String) throws -> RecordingConnection {
        let connection = try RecordingConnection.connect(to: url)
        connection.setReadTimeout(seconds: 3)
        try connection.send(command)
        return connection
    }

    func testStopFromAnotherConnectionReturnsTranscriptToOriginalClient() async throws {
        let url = socketURL()
        let id = UUID()
        var stoppedIDs: [UUID] = []
        let server = RecordingServer(startRecording: { id }) { stoppedID in
            stoppedIDs.append(stoppedID)
            return "A transcript with a newline.\nAnd a second line."
        }
        try server.start(at: url)
        let recording = try connect(url, command: "record")
        let started = try await recording.receiveAsync(RecordingReply.self)
        XCTAssertEqual(started?.event, .started)

        let stop = try connect(url, command: "stop")
        let stopping = try await stop.receiveAsync(RecordingReply.self)
        XCTAssertEqual(stopping?.event, .stopping)
        let result = try await recording.receiveAsync(RecordingReply.self)
        XCTAssertEqual(result?.event, .completed)
        XCTAssertEqual(result?.text, "A transcript with a newline.\nAnd a second line.")
        XCTAssertEqual(stoppedIDs, [id])
        withExtendedLifetime(server) {}
    }

    func testHalfCloseStopsOnceAndStillReceivesTranscript() async throws {
        let url = socketURL()
        var stops = 0
        let server = RecordingServer(startRecording: { UUID() }) { _ in
            stops += 1
            return "hello"
        }
        try server.start(at: url)
        let recording = try connect(url, command: "record")
        _ = try await recording.receiveAsync(RecordingReply.self)
        recording.stopRecording()
        recording.stopRecording()
        let reply = try await recording.receiveAsync(RecordingReply.self)
        XCTAssertEqual(reply?.text, "hello")
        XCTAssertEqual(stops, 1)
        withExtendedLifetime(server) {}
    }

    func testTranscribeFileReturnsTextWithoutStartingCapture() async throws {
        let url = socketURL()
        let audioURL = URL(fileURLWithPath: "/tmp/example recording.wav")
        var starts = 0
        let server = RecordingServer(
            startRecording: {
                starts += 1
                return UUID()
            },
            transcribeFile: { receivedURL in
                XCTAssertEqual(receivedURL.path, audioURL.path)
                return "First line.\nSecond line."
            },
            finishRecording: { _ in "unexpected" }
        )
        try server.start(at: url)
        let connection = try connect(url, command: "transcribe")
        try connection.send(audioURL.path)
        let reply = try await connection.receiveAsync(RecordingReply.self)
        XCTAssertEqual(reply?.event, .completed)
        XCTAssertEqual(reply?.text, "First line.\nSecond line.")
        XCTAssertEqual(starts, 0)
        withExtendedLifetime(server) {}
    }

    func testBusyAndNoActiveRecordingDoNotStopUnrelatedCapture() async throws {
        let url = socketURL()
        var starts = 0
        var stops = 0
        let server = RecordingServer(startRecording: {
            starts += 1
            return UUID()
        }) { _ in
            stops += 1
            return "first"
        }
        try server.start(at: url)
        let idleStop = try connect(url, command: "stop")
        let idleReply = try await idleStop.receiveAsync(RecordingReply.self)
        XCTAssertEqual(idleReply?.event, .failed)
        XCTAssertEqual(stops, 0)

        let first = try connect(url, command: "record")
        _ = try await first.receiveAsync(RecordingReply.self)
        let second = try connect(url, command: "record")
        let busy = try await second.receiveAsync(RecordingReply.self)
        XCTAssertEqual(busy?.event, .failed)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)

        first.stopRecording()
        _ = try await first.receiveAsync(RecordingReply.self)
        XCTAssertEqual(stops, 1)
        withExtendedLifetime(server) {}
    }

    func testDisconnectDuringStartupStillFinishesCapture() async throws {
        let url = socketURL()
        let started = expectation(description: "capture startup")
        let finished = expectation(description: "capture finished")
        var resumeStartup: CheckedContinuation<Void, Never>?
        let server = RecordingServer(startRecording: {
            await withCheckedContinuation { continuation in
                resumeStartup = continuation
                started.fulfill()
            }
            return UUID()
        }) { _ in
            finished.fulfill()
            return "discarded"
        }
        try server.start(at: url)
        let recording = try connect(url, command: "record")
        await fulfillment(of: [started], timeout: 3)
        recording.disconnect()
        resumeStartup?.resume()
        await fulfillment(of: [finished], timeout: 3)
        withExtendedLifetime(server) {}
    }

    func testExternalStopDuringStartupIsRemembered() async throws {
        let url = socketURL()
        let starting = expectation(description: "capture startup")
        var resumeStartup: CheckedContinuation<Void, Never>?
        var stops = 0
        let server = RecordingServer(startRecording: {
            await withCheckedContinuation { continuation in
                resumeStartup = continuation
                starting.fulfill()
            }
            return UUID()
        }) { _ in
            stops += 1
            return "short recording"
        }
        try server.start(at: url)
        let recording = try connect(url, command: "record")
        await fulfillment(of: [starting], timeout: 3)
        let stop = try connect(url, command: "stop")
        let reply = try await stop.receiveAsync(RecordingReply.self)
        XCTAssertEqual(reply?.event, .stopping)
        resumeStartup?.resume()
        _ = try await recording.receiveAsync(RecordingReply.self)
        let result = try await recording.receiveAsync(RecordingReply.self)
        XCTAssertEqual(result?.text, "short recording")
        XCTAssertEqual(stops, 1)
        withExtendedLifetime(server) {}
    }

    func testStartupFailureReleasesSessionAndReportsError() async throws {
        let url = socketURL()
        var attempts = 0
        var stops = 0
        let server = RecordingServer(startRecording: {
            attempts += 1
            if attempts == 1 { throw RecordingCommandError("Microphone access is required.") }
            return UUID()
        }) { _ in
            stops += 1
            throw RecordingCommandError("No speech was detected.")
        }
        try server.start(at: url)
        let first = try connect(url, command: "record")
        let error = try await first.receiveAsync(RecordingReply.self)
        XCTAssertEqual(error?.event, .failed)
        XCTAssertEqual(error?.message, "Microphone access is required.")
        XCTAssertEqual(stops, 0)
        let next = try connect(url, command: "record")
        let started = try await next.receiveAsync(RecordingReply.self)
        XCTAssertEqual(started?.event, .started)
        next.stopRecording()
        let failure = try await next.receiveAsync(RecordingReply.self)
        XCTAssertEqual(failure?.event, .failed)
        XCTAssertEqual(failure?.message, "No speech was detected.")
        XCTAssertEqual(stops, 1)
        withExtendedLifetime(server) {}
    }

    func testSecondServerCannotReplaceLiveSocket() async throws {
        let url = socketURL()
        let first = RecordingServer(startRecording: { UUID() }, finishRecording: { _ in "first" })
        let second = RecordingServer(startRecording: { UUID() }, finishRecording: { _ in "second" })
        try first.start(at: url)
        XCTAssertThrowsError(try second.start(at: url))
        let recording = try connect(url, command: "record")
        _ = try await recording.receiveAsync(RecordingReply.self)
        recording.stopRecording()
        let reply = try await recording.receiveAsync(RecordingReply.self)
        XCTAssertEqual(reply?.text, "first")
        withExtendedLifetime(first) {}
    }
}
