import XCTest
@testable import OpenGlasses

/// Fake tiered transport for testing the M4 -> M2 -> local-file fallback logic without
/// hitting real network.
final class FakeSyncTransport: SyncTransport {
    var m4ShouldSucceed = true
    var m2ShouldSucceed = true
    var m4Calls = 0
    var m2Calls = 0

    func postToM4(_ payload: Data) async -> Bool { m4Calls += 1; return m4ShouldSucceed }
    func postToM2(_ payload: Data) async -> Bool { m2Calls += 1; return m2ShouldSucceed }
}

@MainActor
final class ConversationSyncClientTests: XCTestCase {

    private var tempFiles: [URL] = []
    private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll(); tempDirs.removeAll()
        super.tearDown()
    }

    private func makeQueue() -> ConversationSyncQueue {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csc_\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return ConversationSyncQueue(path: url)
    }

    private func makeDocsDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("docs_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func makeThread() -> ConversationThread {
        var thread = ConversationThread(mode: "chat")
        thread.messages = [
            ConversationMessage(role: "user", content: "hello"),
            ConversationMessage(role: "assistant", content: "hi there"),
        ]
        return thread
    }

    func testSyncThreadSucceedsOnM4() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: makeDocsDir())
        await client.syncThread(makeThread())
        XCTAssertEqual(transport.m4Calls, 1)
        XCTAssertEqual(transport.m2Calls, 0)
        XCTAssertEqual(queue.counts()[.confirmedM4], 1)
    }

    func testFallsBackToM2WhenM4Fails() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        transport.m4ShouldSucceed = false
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: makeDocsDir())
        await client.syncThread(makeThread())
        XCTAssertEqual(transport.m4Calls, 1)
        XCTAssertEqual(transport.m2Calls, 1)
        XCTAssertEqual(queue.counts()[.confirmedM2], 1)
    }

    func testWritesLocalFileWhenBothFail() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        transport.m4ShouldSucceed = false
        transport.m2ShouldSucceed = false
        let docsDir = makeDocsDir()
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: docsDir)
        await client.syncThread(makeThread())
        XCTAssertEqual(queue.counts()[.savedLocalFile], 1)
        let files = try? FileManager.default.contentsOfDirectory(atPath: docsDir.path)
        XCTAssertEqual(files?.count, 1)
    }

    func testEmptyThreadIsNotEnqueued() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: makeDocsDir())
        await client.syncThread(ConversationThread(mode: "chat"))   // no messages -> no pairs
        XCTAssertEqual(transport.m4Calls, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }
}
