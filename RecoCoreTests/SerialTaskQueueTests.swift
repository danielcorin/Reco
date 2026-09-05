import XCTest

@testable import RecoCore

final class SerialTaskQueueTests: XCTestCase {
    @MainActor
    func testSuspendedOperationsFinishInSubmissionOrder() async {
        let queue = SerialTaskQueue()
        let started = Gate()
        let resume = Gate()
        var events: [String] = []

        queue.enqueue {
            events.append("first started")
            started.open()
            await resume.wait()
            events.append("first finished")
        }
        let second = queue.enqueue {
            events.append("second")
        }

        await started.wait()
        XCTAssertEqual(events, ["first started"])
        resume.open()
        await second.value
        XCTAssertEqual(events, ["first started", "first finished", "second"])
    }

    @MainActor
    func testCanEnqueueAfterDrainingAndFromAnOperation() async {
        let queue = SerialTaskQueue()
        var events: [Int] = []
        await queue.enqueue { events.append(1) }.value

        var nested: Task<Void, Never>?
        await queue.enqueue {
            events.append(2)
            nested = queue.enqueue { events.append(3) }
        }.value
        await nested?.value
        await queue.enqueue { events.append(4) }.value

        XCTAssertEqual(events, [1, 2, 3, 4])
    }
}

@MainActor
private final class Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
