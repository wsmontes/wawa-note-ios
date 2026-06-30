import XCTest

@testable import Wawa_Note

final class BackgroundWorkerTests: XCTestCase {
    private var worker: BackgroundWorker!

    override func setUp() {
        worker = BackgroundWorker()
    }

    // MARK: - parseIngestionJSON

    func testParseIngestionJSON_validJSON_returnsResponse() async {
        let json = """
            {"item_project_view":"This note discusses API design","connections":[{"from_title":"Note A","to_title":"Task B","type":"supports"}]}
            """
        let result = await worker.parseIngestionJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.item_project_view, "This note discusses API design")
        XCTAssertEqual(result?.connections?.count, 1)
        XCTAssertEqual(result?.connections?.first?.from_title, "Note A")
    }

    func testParseIngestionJSON_markdownWrapped_returnsResponse() async {
        let json = """
            Here is the analysis:
            ```json
            {"project_item_view":"Relevant to backend refactor","new_tasks":[{"title":"Update schema","priority":"high"}]}
            ```
            Hope this helps!
            """
        let result = await worker.parseIngestionJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.project_item_view, "Relevant to backend refactor")
        XCTAssertEqual(result?.new_tasks?.count, 1)
        XCTAssertEqual(result?.new_tasks?.first?.title, "Update schema")
    }

    func testParseIngestionJSON_garbage_returnsNil() async {
        let result = await worker.parseIngestionJSON("this is not json at all !!!")
        XCTAssertNil(result)
    }

    // MARK: - buildIngestionPrompt

    func testBuildIngestionPrompt_returnsExpectedStructure() async {
        let prompt = await worker.buildIngestionPrompt(
            projectContext: "Project has 5 tasks",
            newItemContext: "New voice memo about auth",
            frameworkID: "fw-123"
        )
        XCTAssertTrue(prompt.contains("## NEW ITEM TO ANALYZE"))
        XCTAssertTrue(prompt.contains("New voice memo about auth"))
        XCTAssertTrue(prompt.contains("## CURRENT PROJECT STATE"))
        XCTAssertTrue(prompt.contains("Project has 5 tasks"))
        XCTAssertTrue(prompt.contains("Return JSON per the schema"))
    }

    // MARK: - extractMentionedNames

    func testExtractMentionedNames_findsCapitalizedNames() async {
        let text = "I spoke with John Smith about the project. Later Maria Garcia confirmed the timeline."
        let names = await worker.extractMentionedNames(from: text)
        XCTAssertTrue(names.contains("John Smith"))
        XCTAssertTrue(names.contains("Maria Garcia"))
        // Single capitalized words (like "I", "Later") should NOT appear
        XCTAssertFalse(names.contains(where: { $0.components(separatedBy: " ").count < 2 }))
    }
}

// MARK: - AsyncSemaphore Tests

final class AsyncSemaphoreTests: XCTestCase {

    func testSemaphoreLimitsConcurrency() async {
        let semaphore = AsyncSemaphore(count: 2)
        let counter = MaxCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await semaphore.acquire()
                    await counter.increment()
                    // Simulate work
                    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                    await counter.decrement()
                    await semaphore.release()
                }
            }
        }

        let maxObserved = await counter.maxConcurrent
        XCTAssertLessThanOrEqual(maxObserved, 2, "Concurrency exceeded semaphore limit")
        XCTAssertGreaterThan(maxObserved, 0, "At least one task should have run")
    }

    func testSemaphoreReleaseUnblocksWaiters() async {
        let semaphore = AsyncSemaphore(count: 1)
        await semaphore.acquire()  // fill the single slot

        let unblocked = expectation(description: "Waiter unblocked")

        Task {
            await semaphore.acquire()  // should block until release
            unblocked.fulfill()
        }

        // Small delay to ensure the waiter is actually waiting
        try? await Task.sleep(nanoseconds: 50_000_000)
        await semaphore.release()

        await fulfillment(of: [unblocked], timeout: 2.0)
    }
}

// MARK: - Helper

/// Thread-safe counter that tracks maximum concurrent value.
private actor MaxCounter {
    private var current = 0
    private(set) var maxConcurrent = 0

    func increment() {
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
    }

    func decrement() {
        current -= 1
    }
}
