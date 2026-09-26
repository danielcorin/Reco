import Darwin
import Foundation

public struct RecordingCommandError: LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RecordingReply: Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        case started, stopping, completed, failed
    }

    public var event: Event
    public var text: String?
    public var message: String?

    public init(event: Event, text: String? = nil, message: String? = nil) {
        self.event = event
        self.text = text
        self.message = message
    }
}

/// A private, same-user connection. The client closes its write half to stop
/// capture, while keeping the read half open for the final transcript.
public final class RecordingConnection: @unchecked Sendable {
    public static var socketURL: URL {
        URL(fileURLWithPath: "/tmp/reco-\(getuid())", isDirectory: true)
            .appendingPathComponent("recording.sock")
    }

    private let descriptor: Int32
    private var buffer = Data()
    private static let maximumMessageSize = 16 * 1024 * 1024

    init(descriptor: Int32) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else {
            Darwin.close(descriptor)
            throw RecordingCommandError("The recording connection belongs to another user.")
        }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        self.descriptor = descriptor
    }

    public static func connect(to url: URL = socketURL) throws -> RecordingConnection {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        do {
            try withSocketAddress(url) { address, length in
                guard Darwin.connect(descriptor, address, length) == 0 else {
                    throw RecordingCommandError("Couldn’t connect to Reco. Open the Reco app and try again.")
                }
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return try RecordingConnection(descriptor: descriptor)
    }

    deinit { Darwin.close(descriptor) }

    public func stopRecording() {
        // shutdown is idempotent, and can safely run while receive is blocked.
        Darwin.shutdown(descriptor, SHUT_WR)
    }

    public func disconnect() { Darwin.shutdown(descriptor, SHUT_RDWR) }

    func stopWaiting() { Darwin.shutdown(descriptor, SHUT_RD) }

    public func setReadTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    // Each direction has a single caller. Reads and writes may run concurrently.
    public func send<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count < Self.maximumMessageSize else {
            throw RecordingCommandError("The recording response is too large.")
        }
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return try JSONDecoder().decode(type, from: line)
            }
            guard buffer.count < Self.maximumMessageSize else {
                throw RecordingCommandError("The recording message is too large.")
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 {
                guard buffer.isEmpty else { throw RecordingCommandError("Incomplete recording message.") }
                return nil
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    func receiveAsync<T: Decodable & Sendable>(_ type: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.receive(type) })
            }
        }
    }

    func sendAsync(_ reply: RecordingReply) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.send(reply) })
            }
        }
    }
}

final class RecordingListener {
    private let source: DispatchSourceRead

    init(url: URL, onConnection: @escaping @Sendable (RecordingConnection) -> Void) throws {
        let directory = url.deletingLastPathComponent()
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
            info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o077 == 0
        else { throw RecordingCommandError("The recording socket directory must be private to your user.") }

        // Hold a lock for the listener's lifetime so a second app cannot unlink
        // the live socket. A subsequent launch can safely remove a stale socket.
        let lock = Darwin.open(
            directory.appendingPathComponent("recording.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            throw RecordingCommandError("Another Reco app is already serving recording commands.")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            Darwin.close(lock)
            throw POSIXError(.ENFILE)
        }
        do {
            unlink(url.path)
            try withSocketAddress(url) { address, length in
                guard bind(descriptor, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard chmod(url.path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        } catch {
            Darwin.close(descriptor)
            unlink(url.path)
            Darwin.close(lock)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0, errno == EINTR { continue }
                guard client >= 0 else { return }
                // Accepted sockets must use blocking I/O on the worker queues.
                _ = fcntl(client, F_SETFL, 0)
                if let connection = try? RecordingConnection(descriptor: client) {
                    onConnection(connection)
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
            unlink(url.path)
            Darwin.close(lock)
        }
        source.resume()
    }

    deinit { source.cancel() }
}

private func withSocketAddress<T>(
    _ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(url.path.utf8CString)
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw RecordingCommandError("The recording socket path is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        bytes.copyBytes(from: path.map { UInt8(bitPattern: $0) })
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
