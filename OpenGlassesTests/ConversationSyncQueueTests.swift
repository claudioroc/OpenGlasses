import XCTest
@testable import OpenGlasses

@MainActor
final class ConversationSyncQueueTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func tempPath() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csq_\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return url
    }

    private func item(_ session: String, at seconds: TimeInterval) -> SyncItem {
        SyncItem(sessionId: session, payload: Data(), createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testEnqueueAndPendingAreFIFOByCreatedAt() {
        let q = ConversationSyncQueue(path: tempPath())
        let a = item("s1", at: 300)
        let b = item("s2", at: 100)
        let c = item("s3", at: 200)
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        XCTAssertEqual(q.pending().map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(q.pendingCount, 3)
    }

    func testMarkConfirmedM4RemovesFromPending() {
        let q = ConversationSyncQueue(path: tempPath())
        let a = item("s1", at: 100)
        q.enqueue(a)
        q.mark(a.id, state: .confirmedM4)
        XCTAssertTrue(q.pending().isEmpty)
    }

    func testSurvivesReopen() {
        let path = tempPath()
        let a = item("s1", at: 100)
        do {
            let q = ConversationSyncQueue(path: path)
            q.enqueue(a)
        }
        let reopened = ConversationSyncQueue(path: path)
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(reopened.pending().first?.id, a.id)
    }

    func testInFlightIsRecoveredToPendingOnReopen() {
        let path = tempPath()
        let a = item("s1", at: 100)
        do {
            let q = ConversationSyncQueue(path: path)
            q.enqueue(a)
            q.mark(a.id, state: .inFlight)   // simulates a kill mid-delivery
        }
        let reopened = ConversationSyncQueue(path: path)
        XCTAssertEqual(reopened.pending().map(\.id), [a.id])   // strand recovered, not lost
    }
}
