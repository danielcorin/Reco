import Combine
import Foundation
import RecoCore

/// Owns the menu's copy of the usage stats and persists one update per
/// transcription. The file stays the source of truth: it is reread before each
/// update so a reset (deleting the file) or an edit is never overwritten.
@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var stats = UsageStats()

    private let store: UsageStatsStore

    init(store: UsageStatsStore = UsageStatsStore()) {
        self.store = store
        refresh()
    }

    func refresh() {
        do {
            let loaded = try store.load()
            if stats != loaded { stats = loaded }
        } catch {
            NSLog("Reco: %@", error.localizedDescription)
        }
    }

    func record(_ text: String, at date: Date = Date()) {
        let words = UsageStats.wordCount(text)
        do {
            var updated = try store.load()
            updated.record(words: words, at: date)
            try store.save(updated)
            stats = updated
        } catch {
            // An unreadable file is left untouched so a bad edit never erases
            // history; the menu still counts this session.
            stats.record(words: words, at: date)
            NSLog("Reco: couldn’t update usage stats: %@", error.localizedDescription)
        }
    }
}
