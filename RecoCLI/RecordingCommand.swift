import Darwin
import Foundation
import RecoCore

private struct TranscriptOutput: Encodable {
    var text: String
}

private struct StopOutput: Encodable {
    var stopping = true
}

func runRecordingCommand(_ action: String, arguments: [String], json: Bool) throws {
    let duration: Double?
    if action == "record" {
        if arguments.isEmpty {
            duration = nil
        } else if arguments.count == 2, arguments[0] == "--duration",
            let seconds = Double(arguments[1]), seconds.isFinite, seconds > 0,
            seconds < Double(Int.max) / 1_000_000_000
        {
            duration = seconds
        } else {
            throw UsageError("record accepts --duration followed by a positive number of seconds")
        }
    } else {
        guard arguments.isEmpty else { throw UsageError("stop takes no arguments") }
        duration = nil
    }

    let connection = try RecordingConnection.connect()
    defer { connection.disconnect() }
    let stopControl = action == "record" ? RecordingStopControl(connection: connection) : nil
    defer { stopControl?.finish() }
    connection.setReadTimeout(seconds: 30)
    try connection.send(action)
    guard let reply = try connection.receive(RecordingReply.self) else {
        throw RecordingCommandError("Reco closed the connection before recording started.")
    }
    if reply.event == .failed {
        throw RecordingCommandError(reply.message ?? "The recording command failed.")
    }
    if action == "stop" {
        guard reply.event == .stopping else { throw RecordingCommandError("Unexpected response from Reco.") }
        if json {
            try writeJSON(StopOutput())
        } else {
            print("Stopping CLI recording. The original reco record command will return the transcript.")
        }
        return
    }

    guard reply.event == .started else { throw RecordingCommandError("Unexpected response from Reco.") }
    connection.setReadTimeout(seconds: 0)
    stopControl?.recordingStarted(duration: duration)
    guard let result = try connection.receive(RecordingReply.self) else {
        throw RecordingCommandError("Reco disconnected before returning the transcript.")
    }
    stopControl?.finish()
    guard result.event == .completed, let text = result.text else {
        throw RecordingCommandError(result.message ?? "Reco did not return a transcript.")
    }
    if json {
        try writeJSON(TranscriptOutput(text: text))
    } else {
        print(text)
    }
}

/// Signal handlers run on a dispatch queue while the command waits for a reply.
/// They request a graceful stop; the process stays alive to print the transcript.
private final class RecordingStopControl: @unchecked Sendable {
    private let connection: RecordingConnection
    private let queue = DispatchQueue(label: "llc.wvlen.Reco.cli-stop")
    private var sources: [DispatchSourceSignal] = []
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(connection: RecordingConnection) {
        self.connection = connection
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.requestStop() }
            source.resume()
            sources.append(source)
        }
    }

    func recordingStarted(duration: Double?) {
        queue.async { [self] in
            guard !stopped else { return }
            FileHandle.standardError.write(Data("Recording. Use Ctrl-C or reco stop to finish.\n".utf8))
            if let duration {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + duration)
                timer.setEventHandler { [weak self] in self?.requestStop() }
                self.timer = timer
                timer.resume()
            }
        }
    }

    private func requestStop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        connection.stopRecording()
        FileHandle.standardError.write(Data("Stopping recording; waiting for transcription…\n".utf8))
    }

    func finish() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            sources.forEach { $0.cancel() }
        }
    }

    deinit {
        for number in [SIGINT, SIGTERM, SIGHUP] { signal(number, SIG_DFL) }
    }
}
