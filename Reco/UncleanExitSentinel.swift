import Foundation

/// A per-run marker used to detect crashes. The marker holds this run's
/// process id and is removed on a clean quit; finding a marker whose process
/// is gone means the previous run died without cleaning up.
enum UncleanExitSentinel {
    private static var markerURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Reco", isDirectory: true)
            .appendingPathComponent("session.pid")
    }

    /// Records this run and reports whether the previous one ended uncleanly.
    /// A marker owned by a live process is a launch-agent handoff between two
    /// Reco instances, not a crash.
    static func beginSession() -> Bool {
        let url = markerURL
        var previousRunCrashed = false
        if let recorded = try? String(contentsOf: url, encoding: .utf8),
            let pid = pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            previousRunCrashed = kill(pid, 0) != 0 && errno == ESRCH
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return previousRunCrashed
    }

    /// Removes the marker if this run still owns it. After a handoff the newer
    /// instance owns the marker, and its cleanup is its own.
    static func endSession() {
        guard let recorded = try? String(contentsOf: markerURL, encoding: .utf8),
            pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
                == ProcessInfo.processInfo.processIdentifier
        else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }
}
