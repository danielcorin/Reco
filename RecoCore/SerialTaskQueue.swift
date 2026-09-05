import Foundation

/// Keeps asynchronous operations in submission order, including across suspension points.
@MainActor
public final class SerialTaskQueue {
    private var tail: Task<Void, Never>?
    private var tailID: UUID?

    public init() {}

    @discardableResult
    public func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let id = UUID()
        tailID = id
        let task = Task {
            await previous?.value
            await operation()
            if tailID == id {
                tail = nil
                tailID = nil
            }
        }
        tail = task
        return task
    }
}
