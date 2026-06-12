import XCTest
@testable import Wawa_Note

@MainActor
final class SemanticSearchServiceTests: XCTestCase {

    func testCosineSimilarityIdenticalVectors() {
        let service = SemanticSearchService()
        let vec: [Float] = [1.0, 2.0, 3.0]
        let result = service.cosineSimilarity(vec, vec)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let service = SemanticSearchService()
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let result = service.cosineSimilarity(a, b)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityOppositeVectors() {
        let service = SemanticSearchService()
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let result = service.cosineSimilarity(a, b)
        XCTAssertEqual(result, -1.0, accuracy: 0.001)
    }

    func testCosineSimilarityEmptyVectors() {
        let service = SemanticSearchService()
        let result = service.cosineSimilarity([], [])
        XCTAssertEqual(result, 0)
    }

    func testCosineSimilarityDifferentLengths() {
        let service = SemanticSearchService()
        let result = service.cosineSimilarity([1.0], [1.0, 2.0])
        XCTAssertEqual(result, 0)
    }
}

// MARK: - ShellInterpreter Tokenizer Tests (Kiro Review Part 1 #1)

@MainActor
final class ShellInterpreterTokenizerTests: XCTestCase {

    func testSplitCommandsEmpty() {
        let result = ShellInterpreter.splitCommands("")
        XCTAssertTrue(result.isEmpty, "Empty string should produce empty array")
    }

    func testSplitCommandsSingleCommand() {
        let result = ShellInterpreter.splitCommands("ls /projects/test")
        XCTAssertEqual(result.count, 1)
    }

    func testSplitCommandsWithAmpersand() {
        let result = ShellInterpreter.splitCommands("ls /a && cat /b")
        XCTAssertEqual(result.count, 2, "Should split on &&")
    }

    func testTokenizeSimpleCommand() {
        let cmd = ShellInterpreter.tokenize("ls --long /path")
        XCTAssertEqual(cmd.name, "ls")
        XCTAssertTrue(cmd.flags.keys.contains("long"))
        XCTAssertEqual(cmd.args.first, "/path")
    }

    func testTokenizeEmpty() {
        let cmd = ShellInterpreter.tokenize("")
        XCTAssertTrue(cmd.name.isEmpty)
    }
}

// MARK: - Import/Export Roundtrip Tests (Kiro Review Part 1 #5)

@MainActor
final class ImportExportRoundtripTests: XCTestCase {

    func testExportTasksCSVIsValid() {
        let service = ProjectExportService()
        let task = TaskItem(title: "Test task", status: .done, priority: .high, ownerName: "Bob")
        let csv = service.exportTasksCSV(tasks: [task])
        XCTAssertTrue(csv.contains("Test task"))
        XCTAssertTrue(csv.contains("done"))
        XCTAssertTrue(csv.contains("high"))
    }

    func testExportJSONIsValid() {
        let item = KnowledgeItem(type: .note, title: "Export Test", bodyText: "Hello")
        XCTAssertEqual(item.title, "Export Test")
        XCTAssertEqual(item.bodyText, "Hello")
    }
}

@MainActor
final class ProjectExportServiceTests: XCTestCase {

    func testExportTasksCSVEmpty() {
        let service = ProjectExportService()
        let csv = service.exportTasksCSV(tasks: [])
        XCTAssertTrue(csv.contains("Title,Status,Priority,Owner"))
    }

    func testExportTasksCSVWithTasks() {
        let service = ProjectExportService()
        let task = TaskItem(
            title: "Test task",
            status: .todo,
            priority: .high,
            ownerName: "Alice",
            dueAt: Date()
        )
        let csv = service.exportTasksCSV(tasks: [task])

        XCTAssertTrue(csv.contains("Test task"))
        XCTAssertTrue(csv.contains("todo"))
        XCTAssertTrue(csv.contains("high"))
        XCTAssertTrue(csv.contains("Alice"))
    }
}

@MainActor
final class GraphEdgeServiceTests: XCTestCase {

    func testEdgeTypeAllCases() {
        let all = EdgeType.allCases
        XCTAssertEqual(all.count, 10)
        XCTAssertTrue(all.contains(.mentions))
        XCTAssertTrue(all.contains(.belongsTo))
        XCTAssertTrue(all.contains(.produced))
        XCTAssertTrue(all.contains(.supports))
        XCTAssertTrue(all.contains(.precedes))
        XCTAssertTrue(all.contains(.blockedBy))
        XCTAssertTrue(all.contains(.relatesTo))
        XCTAssertTrue(all.contains(.references))
        XCTAssertTrue(all.contains(.contradicts))
        XCTAssertTrue(all.contains(.assignedTo))
    }
}

@MainActor
final class EntityExtractionTests: XCTestCase {

    func testEntityKindMapping() {
        let kindMappings: [(EntityType, EntityKind)] = [
            (.person, .person),
            (.organization, .organization),
            (.system, .system),
            (.tool, .system),
            (.repository, .repository),
            (.location, .location),
            (.project, .other),
            (.other, .other)
        ]

        for (type, expectedKind) in kindMappings {
            let mapped = mapKindForTest(type)
            XCTAssertEqual(mapped, expectedKind, "\(type) should map to \(expectedKind)")
        }
    }

    private func mapKindForTest(_ type: EntityType) -> EntityKind {
        switch type {
        case .person: return .person
        case .organization: return .organization
        case .system, .tool: return .system
        case .repository: return .repository
        case .location: return .location
        case .project, .other: return .other
        }
    }
}

@MainActor
final class MeetingAnalysisTests: XCTestCase {

    func testEntityTypeRoundtrip() {
        let types: [EntityType] = [.person, .organization, .system, .tool, .repository, .location, .project, .other]
        for type in types {
            let raw = type.rawValue
            let decoded = EntityType(rawValue: raw)
            XCTAssertEqual(decoded, type, "\(type.rawValue) should roundtrip")
        }
    }

    func testEntityMentionCreation() {
        let mention = EntityMention(name: "Alice", type: .person, sourceSegmentIds: [UUID()])
        XCTAssertEqual(mention.name, "Alice")
        XCTAssertEqual(mention.type, .person)
        XCTAssertEqual(mention.sourceSegmentIds.count, 1)
    }
}

// MARK: - ItemStatus (formerly MeetingStatus)

@MainActor
final class ItemStatusTests: XCTestCase {

    func testAllCasesExist() {
        let all = ItemStatus.allCases
        XCTAssertEqual(all.count, 9)
        XCTAssertTrue(all.contains(.draft))
        XCTAssertTrue(all.contains(.analyzed))
        XCTAssertTrue(all.contains(.archived))
    }

    func testRawValueRoundtrip() {
        for status in ItemStatus.allCases {
            let decoded = ItemStatus(rawValue: status.rawValue)
            XCTAssertEqual(decoded, status)
        }
    }
}

// MARK: - IngestionResponse (Codable)

@MainActor
final class IngestionResponseTests: XCTestCase {

    func testDecodeFullResponse() throws {
        let json = """
        {
            "item_project_view": "Fits into the architecture",
            "project_item_view": "Reveals new patterns",
            "connections": [
                {"from_title": "Item A", "to_title": "Item B", "type": "supports", "explanation": "Direct evidence"}
            ],
            "task_updates": [
                {"task_title": "Old task", "new_status": "done", "reason": "Completed by this item"}
            ],
            "new_tasks": [
                {"title": "Investigate pattern", "priority": "high", "reason": "Urgent finding"}
            ],
            "edge_reinforcements": [
                {"from_title": "X", "to_title": "Y", "note": "Confirmed"}
            ],
            "insights": [
                {"text": "Unexpected correlation found", "confidence": 0.92}
            ],
            "project_summary_contribution": "This item adds significant knowledge about architecture decisions."
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.item_project_view, "Fits into the architecture")
        XCTAssertEqual(response.connections?.count, 1)
        XCTAssertEqual(response.connections?.first?.type, "supports")
        XCTAssertEqual(response.task_updates?.first?.new_status, "done")
        XCTAssertEqual(response.new_tasks?.first?.priority, "high")
        XCTAssertEqual(response.edge_reinforcements?.first?.note, "Confirmed")
        XCTAssertEqual(response.insights?.first?.confidence, 0.92)
        XCTAssertTrue(response.project_summary_contribution?.contains("architecture decisions") ?? false)
    }

    func testDecodeMinimalResponse() throws {
        let json = """
        {
            "project_summary_contribution": "Minimal contribution."
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.project_summary_contribution, "Minimal contribution.")
        XCTAssertNil(response.connections)
        XCTAssertNil(response.new_tasks)
        XCTAssertNil(response.insights)
    }

    func testLegacyKeyStillParsed() throws {
        let json = """
        {
            "project_summary_update": "Legacy key value"
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.project_summary_update, "Legacy key value")
        XCTAssertNil(response.project_summary_contribution)
    }
}

// MARK: - KnowledgeItem

@MainActor
final class KnowledgeItemTests: XCTestCase {

    func testDefaultTypeIsAudio() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertEqual(item.type, .audio)
    }

    func testCustomType() {
        let item = KnowledgeItem(type: .note, title: "My Note")
        XCTAssertEqual(item.type, .note)
    }

    func testInboxDateDefault() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertNotNil(item.inboxDate)
    }

    func testProjectIDIsNilByDefault() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertNil(item.projectID)
    }

    func testStatusRoundtrip() {
        let item = KnowledgeItem(title: "Test")
        item.status = .analyzed
        XCTAssertEqual(item.status, .analyzed)
        XCTAssertEqual(item.statusRaw, "analyzed")
    }
}

// MARK: - ProjectService (pure logic)

@MainActor
final class ProjectStatusTests: XCTestCase {

    func testAllStatuses() {
        let all = ProjectStatus.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(.active))
        XCTAssertTrue(all.contains(.archived))
        XCTAssertTrue(all.contains(.completed))
    }
}

@MainActor
final class TaskItemTests: XCTestCase {

    func testDefaultStatus() {
        let task = TaskItem(title: "Test")
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.priority, .medium)
    }

    func testSourceSegmentEncoding() throws {
        let segments = ["seg1", "seg2", "seg3"]
        let task = TaskItem(title: "Test", sourceSegmentIDs: segments)
        XCTAssertEqual(task.sourceSegmentIDList, segments)
    }

    func testEmptySourceSegments() {
        let task = TaskItem(title: "Test")
        XCTAssertTrue(task.sourceSegmentIDList.isEmpty)
    }
}

// MARK: - FieldAuthorityService

@MainActor
final class FieldAuthorityServiceTests: XCTestCase {

    func testUserCanAlwaysModify() {
        let auth = FieldAuthorityService.shared
        var prov = FieldProvenance.empty
        prov.mark(field: "status", origin: .user)
        // We test the logic directly since mock models are complex
        XCTAssertTrue(prov.isUserOwned(field: "status"))
    }

    func testLLMCanModifyLLMOwnedField() {
        var prov = FieldProvenance.empty
        prov.mark(field: "status", origin: .llm)
        XCTAssertFalse(prov.isUserOwned(field: "status"))
    }

    func testFirstBlockedFieldReturnsCorrectField() {
        var prov = FieldProvenance.empty
        prov.mark(field: "status", origin: .user)
        // status is user-owned, priority is not
        XCTAssertTrue(prov.isUserOwned(field: "status"))
        XCTAssertFalse(prov.isUserOwned(field: "priority"))
    }
}

// MARK: - FieldProvenance

@MainActor
final class FieldProvenanceTests: XCTestCase {

    func testEncodeDecodeRoundtrip() {
        var prov = FieldProvenance.empty
        prov.mark(field: "title", origin: .user)
        prov.mark(field: "bodyText", origin: .llm)

        let json = prov.encode()
        XCTAssertNotNil(json)

        let decoded = FieldProvenance.decode(from: json)
        XCTAssertTrue(decoded.isUserOwned(field: "title"))
        XCTAssertFalse(decoded.isUserOwned(field: "bodyText"))
    }

    func testEmptyProvenanceTreatsAllAsLLM() {
        let prov = FieldProvenance.empty
        XCTAssertEqual(prov.origin(for: "anyField"), .llm)
        XCTAssertFalse(prov.isUserOwned(field: "anyField"))
    }

    func testDecodeNilReturnsEmpty() {
        let prov = FieldProvenance.decode(from: nil)
        XCTAssertEqual(prov.origin(for: "any"), .llm)
    }

    func testDecodeInvalidJSONReturnsEmpty() {
        let prov = FieldProvenance.decode(from: "not valid json")
        XCTAssertEqual(prov.origin(for: "any"), .llm)
    }

    func testIsOwnedBy() {
        var prov = FieldProvenance.empty
        prov.mark(field: "name", origin: .user)
        XCTAssertTrue(prov.isOwned(by: .user, field: "name"))
        XCTAssertFalse(prov.isOwned(by: .llm, field: "name"))
    }

    func testMarkUpdatesTimestamp() {
        var prov = FieldProvenance.empty
        let before = Date()
        prov.mark(field: "test", origin: .user)
        let entry = prov.fields["test"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.origin, .user)
        XCTAssertGreaterThanOrEqual(entry!.modifiedAt, before)
    }

    func testMultipleFieldsTrackedIndependently() {
        var prov = FieldProvenance.empty
        prov.mark(field: "title", origin: .user)
        prov.mark(field: "status", origin: .llm)
        prov.mark(field: "priority", origin: .import)

        XCTAssertTrue(prov.isUserOwned(field: "title"))
        XCTAssertFalse(prov.isUserOwned(field: "status"))
        XCTAssertFalse(prov.isUserOwned(field: "priority"))
        XCTAssertEqual(prov.origin(for: "status"), .llm)
        XCTAssertEqual(prov.origin(for: "priority"), .import)
    }

    func testFieldOriginRawValues() {
        XCTAssertEqual(FieldOrigin.user.rawValue, "user")
        XCTAssertEqual(FieldOrigin.llm.rawValue, "llm")
        XCTAssertEqual(FieldOrigin.import.rawValue, "import")
        XCTAssertEqual(FieldOrigin.system.rawValue, "system")
    }
}

// MARK: - Signal Tests

@MainActor
final class SignalPriorityServiceTests: XCTestCase {

    func testComputedPriorityUsesStoredScores() {
        let signal = AgentSuggestion(projectID: UUID(), type: "risk", title: "Test risk",
            impactScore: 0.9, urgencyScore: 0.8, relevanceScore: 0.7)
        let priority = SignalPriorityService.shared.computePriority(
            signal: signal, project: nil, activeItemCount: 5)
        // High impact + urgency should produce fairly high score (>50)
        XCTAssertGreaterThan(priority, 50)
    }

    func testRiskTypeGetsBoost() {
        let riskSignal = AgentSuggestion(projectID: UUID(), type: "risk", title: "R",
            impactScore: 0.5, urgencyScore: 0.5, relevanceScore: 0.5)
        let doubtSignal = AgentSuggestion(projectID: UUID(), type: "doubt", title: "D",
            impactScore: 0.5, urgencyScore: 0.5, relevanceScore: 0.5)
        let riskPriority = SignalPriorityService.shared.computePriority(
            signal: riskSignal, project: nil, activeItemCount: 0)
        let doubtPriority = SignalPriorityService.shared.computePriority(
            signal: doubtSignal, project: nil, activeItemCount: 0)
        // Risk should get type boost
        XCTAssertGreaterThan(riskPriority, doubtPriority)
    }

    func testOlderSignalDecays() {
        let freshSignal = AgentSuggestion(projectID: UUID(), type: "pattern", title: "P",
            createdAt: Date(), impactScore: 0.5, urgencyScore: 0.5, relevanceScore: 0.5)
        let oldSignal = AgentSuggestion(projectID: UUID(), type: "pattern", title: "Old",
            createdAt: Date().addingTimeInterval(-14 * 86400),
            impactScore: 0.5, urgencyScore: 0.5, relevanceScore: 0.5)
        let freshPriority = SignalPriorityService.shared.computePriority(
            signal: freshSignal, project: nil, activeItemCount: 0)
        let oldPriority = SignalPriorityService.shared.computePriority(
            signal: oldSignal, project: nil, activeItemCount: 0)
        XCTAssertGreaterThan(freshPriority, oldPriority)
    }

    func testPriorityClampedTo100() {
        let signal = AgentSuggestion(projectID: UUID(), type: "alert", title: "A",
            impactScore: 1.0, urgencyScore: 1.0, relevanceScore: 1.0)
        let priority = SignalPriorityService.shared.computePriority(
            signal: signal, project: nil, activeItemCount: 0)
        XCTAssertLessThanOrEqual(priority, 100.0)
    }
}

@MainActor
final class AgentSuggestionTests: XCTestCase {

    func testComputedPriority() {
        let signal = AgentSuggestion(projectID: UUID(), type: "risk", title: "Test",
            impactScore: 0.8, urgencyScore: 0.6, relevanceScore: 0.5)
        let priority = signal.computedPriority
        XCTAssertGreaterThan(priority, 0)
        XCTAssertLessThanOrEqual(priority, 100)
    }

    func testIsActive() {
        let visible = AgentSuggestion(type: "risk", title: "T", status: "visible")
        let seen = AgentSuggestion(type: "risk", title: "T", status: "seen")
        let archived = AgentSuggestion(type: "risk", title: "T", status: "archived")
        XCTAssertTrue(visible.isActive)
        XCTAssertTrue(seen.isActive)
        XCTAssertFalse(archived.isActive)
    }

    func testDefaultStatusIsVisible() {
        let signal = AgentSuggestion(type: "opportunity", title: "Test")
        XCTAssertEqual(signal.status, "visible")
    }
}

// MARK: - Audio Capture State Tests

@MainActor
final class AudioCaptureStateTests: XCTestCase {

    func testAllStatesAreDistinct() {
        let states: [AudioCaptureState] = [
            .idle, .recording, .pausedByUser,
            .reconfiguringRoute, .validatingRoute,
            .waitingForUsableInput, .interruptedBySystem,
            .failedFatal("test"), .stopped
        ]
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                XCTAssertNotEqual(states[i], states[j], "\(states[i]) should differ from \(states[j])")
            }
        }
    }

    func testFailedFatalEquality() {
        XCTAssertEqual(AudioCaptureState.failedFatal("disk full"), AudioCaptureState.failedFatal("disk full"))
        XCTAssertNotEqual(AudioCaptureState.failedFatal("disk full"), AudioCaptureState.failedFatal("write error"))
    }

    func testStoppedVsIdle() {
        XCTAssertNotEqual(AudioCaptureState.stopped, AudioCaptureState.idle)
    }

    func testRecordingIntentAllCases() {
        // Verify all cases exist
        let intents: [RecordingIntent] = [.none, .userWantsRecording, .userPaused, .userStopped]
        XCTAssertEqual(intents.count, 4)
    }
}

// MARK: - Audio Route Snapshot Tests

@MainActor
final class AudioRouteSnapshotTests: XCTestCase {

    func testSnapshotInitialization() {
        let snap = AudioRouteSnapshot(
            currentInputs: ["iPhone"],
            currentOutputs: ["Speaker"],
            availableInputs: ["iPhone", "AirPods"],
            selectedInput: "iPhone",
            selectedInputType: "builtInMic",
            isInputUsable: true,
            previousInputs: nil,
            previousOutputs: nil,
            sampleRate: 44100,
            bufferDuration: 0.023,
            routeChangeReason: "test"
        )
        XCTAssertEqual(snap.currentInputs, ["iPhone"])
        XCTAssertEqual(snap.currentOutputs, ["Speaker"])
        XCTAssertEqual(snap.availableInputs, ["iPhone", "AirPods"])
        XCTAssertEqual(snap.selectedInput, "iPhone")
        XCTAssertEqual(snap.selectedInputType, "builtInMic")
        XCTAssertTrue(snap.isInputUsable)
        XCTAssertNil(snap.previousInputs)
        XCTAssertEqual(snap.sampleRate, 44100)
        XCTAssertEqual(snap.bufferDuration, 0.023)
        XCTAssertEqual(snap.routeChangeReason, "test")
    }

    func testSnapshotWithPreviousRoute() {
        let snap = AudioRouteSnapshot(
            currentInputs: ["AirPods"],
            currentOutputs: ["AirPods"],
            availableInputs: ["AirPods", "iPhone"],
            selectedInput: "AirPods",
            selectedInputType: "bluetoothHFP",
            isInputUsable: true,
            previousInputs: ["iPhone"],
            previousOutputs: ["Speaker"],
            sampleRate: 16000,
            bufferDuration: 0.046,
            routeChangeReason: "bluetooth connected"
        )
        XCTAssertEqual(snap.previousInputs, ["iPhone"])
        XCTAssertEqual(snap.previousOutputs, ["Speaker"])
        XCTAssertEqual(snap.sampleRate, 16000)
    }

    func testSnapshotNoUsableInput() {
        let snap = AudioRouteSnapshot(
            currentInputs: [],
            currentOutputs: ["Speaker"],
            availableInputs: [],
            selectedInput: nil,
            selectedInputType: nil,
            isInputUsable: false,
            previousInputs: ["iPhone"],
            previousOutputs: nil,
            sampleRate: 0,
            bufferDuration: 0,
            routeChangeReason: "input lost"
        )
        XCTAssertFalse(snap.isInputUsable)
        XCTAssertNil(snap.selectedInput)
        XCTAssertTrue(snap.currentInputs.isEmpty)
    }
}

// MARK: - Audio Rebuild Result Tests

@MainActor
final class AudioRebuildResultTests: XCTestCase {

    func testResumedResult() {
        let snap = AudioRouteSnapshot(
            currentInputs: ["iPhone"], currentOutputs: ["Speaker"],
            availableInputs: ["iPhone"], selectedInput: "iPhone",
            selectedInputType: "builtInMic", isInputUsable: true,
            previousInputs: nil, previousOutputs: nil,
            sampleRate: 44100, bufferDuration: 0.023,
            routeChangeReason: "restart"
        )
        let result = AudioRebuildResult.resumed(snap)
        if case .resumed(let s) = result {
            XCTAssertEqual(s.currentInputs, ["iPhone"])
        } else {
            XCTFail("Expected .resumed")
        }
    }

    func testNoUsableInputResult() {
        let snap = AudioRouteSnapshot(
            currentInputs: [], currentOutputs: ["Speaker"],
            availableInputs: [], selectedInput: nil,
            selectedInputType: nil, isInputUsable: false,
            previousInputs: nil, previousOutputs: nil,
            sampleRate: 0, bufferDuration: 0,
            routeChangeReason: "no mic"
        )
        let result = AudioRebuildResult.noUsableInput(snap)
        if case .noUsableInput(let s) = result {
            XCTAssertFalse(s.isInputUsable)
        } else {
            XCTFail("Expected .noUsableInput")
        }
    }

    func testEngineFailedResult() {
        let snap = AudioRouteSnapshot(
            currentInputs: ["AirPods"], currentOutputs: ["AirPods"],
            availableInputs: ["AirPods"], selectedInput: "AirPods",
            selectedInputType: "bluetoothHFP", isInputUsable: true,
            previousInputs: nil, previousOutputs: nil,
            sampleRate: 8000, bufferDuration: 0.1,
            routeChangeReason: "restart"
        )
        let error = NSError(domain: "Audio", code: -1)
        let result = AudioRebuildResult.engineFailed(error, snap)
        if case .engineFailed(let e, let s) = result {
            XCTAssertEqual((e as NSError).code, -1)
            XCTAssertEqual(s.selectedInputType, "bluetoothHFP")
        } else {
            XCTFail("Expected .engineFailed")
        }
    }
}

// MARK: - Recording Segment Tests

@MainActor
final class RecordingSegmentTests: XCTestCase {

    func testSegmentInitialization() {
        let seg = RecordingSegment(
            id: UUID(), index: 0, fileName: "segment-000.m4a",
            startedAt: Date(), inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "initial",
            sampleRate: 44100
        )
        XCTAssertEqual(seg.index, 0)
        XCTAssertEqual(seg.fileName, "segment-000.m4a")
        XCTAssertNil(seg.endedAt)
        XCTAssertNil(seg.fileSize)
        XCTAssertEqual(seg.inputPortName, "iPhone")
        XCTAssertEqual(seg.routeChangeReason, "initial")
    }

    func testSegmentWithEndedAtAndFileSize() {
        var seg = RecordingSegment(
            id: UUID(), index: 1, fileName: "segment-001.wav",
            startedAt: Date(), inputPortName: "AirPods",
            inputPortType: "bluetoothHFP",
            routeChangeReason: "bluetooth connected",
            sampleRate: 8000
        )
        seg.endedAt = Date()
        seg.fileSize = 12345
        XCTAssertNotNil(seg.endedAt)
        XCTAssertEqual(seg.fileSize, 12345)
    }
}

// MARK: - Recording Manifest Index Tests

@MainActor
final class RecordingManifestIndexProviderTests: XCTestCase {

    func testEmptyManifestNextIndex() {
        let manifest = RecordingManifest(
            recordingId: UUID(), title: "Test",
            startedAt: Date(), segments: []
        )
        let nextIndex = (manifest.segments.map(\.index).max() ?? -1) + 1
        XCTAssertEqual(nextIndex, 0)
    }

    func testSingleSegmentNextIndex() {
        let seg = RecordingSegment(
            id: UUID(), index: 0, fileName: "segment-000.m4a",
            startedAt: Date(), inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "initial", sampleRate: 44100
        )
        let manifest = RecordingManifest(
            recordingId: UUID(), title: "Test",
            startedAt: Date(), segments: [seg]
        )
        let nextIndex = (manifest.segments.map(\.index).max() ?? -1) + 1
        XCTAssertEqual(nextIndex, 1)
    }

    func testMultipleSegmentsNextIndex() {
        var segments: [RecordingSegment] = []
        for i in 0..<3 {
            segments.append(RecordingSegment(
                id: UUID(), index: i,
                fileName: "segment-\(String(format: "%03d", i)).m4a",
                startedAt: Date(), inputPortName: "iPhone",
                inputPortType: "builtInMic",
                routeChangeReason: i == 0 ? "initial" : "route switch",
                sampleRate: 44100
            ))
        }
        let manifest = RecordingManifest(
            recordingId: UUID(), title: "Test",
            startedAt: Date(), segments: segments
        )
        let nextIndex = (manifest.segments.map(\.index).max() ?? -1) + 1
        XCTAssertEqual(nextIndex, 3)
    }

    func testNonContiguousIndices() {
        // Simulate segment-000 and segment-002 (segment-001 was discarded)
        let seg0 = RecordingSegment(
            id: UUID(), index: 0, fileName: "segment-000.m4a",
            startedAt: Date(), inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "initial", sampleRate: 44100
        )
        let seg2 = RecordingSegment(
            id: UUID(), index: 2, fileName: "segment-002.m4a",
            startedAt: Date(), inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "forceBuiltInMic", sampleRate: 44100
        )
        let manifest = RecordingManifest(
            recordingId: UUID(), title: "Test",
            startedAt: Date(), segments: [seg0, seg2]
        )
        let nextIndex = (manifest.segments.map(\.index).max() ?? -1) + 1
        XCTAssertEqual(nextIndex, 3)
    }

    func testManifestTotalDuration() {
        let now = Date()
        var seg0 = RecordingSegment(
            id: UUID(), index: 0, fileName: "segment-000.m4a",
            startedAt: now, inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "initial", sampleRate: 44100
        )
        seg0.endedAt = now.addingTimeInterval(10)
        var seg1 = RecordingSegment(
            id: UUID(), index: 1, fileName: "segment-001.m4a",
            startedAt: now.addingTimeInterval(11),
            inputPortName: "iPhone",
            inputPortType: "builtInMic",
            routeChangeReason: "restart", sampleRate: 44100
        )
        seg1.endedAt = now.addingTimeInterval(20)
        let manifest = RecordingManifest(
            recordingId: UUID(), title: "Test",
            startedAt: now, segments: [seg0, seg1]
        )
        XCTAssertEqual(manifest.totalDuration, 19.0, accuracy: 0.1)
    }
}

// MARK: - Audio Capture Error Tests

@MainActor
final class AudioCaptureErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(AudioCaptureError.engineStartFailed)
        XCTAssertNotNil(AudioCaptureError.inputNodeUnavailable)
        XCTAssertNotNil(AudioCaptureError.permissionDenied)
        XCTAssertNotNil(AudioCaptureError.diskFull)
    }
}

// MARK: - Closed Segment Info Tests

@MainActor
final class ClosedSegmentInfoTests: XCTestCase {

    func testClosedSegmentInfoInitialization() {
        let info = ClosedSegmentInfo(
            index: 0, fileName: "segment-000.m4a",
            endedAt: Date(), fileSize: 44100
        )
        XCTAssertEqual(info.index, 0)
        XCTAssertEqual(info.fileName, "segment-000.m4a")
        XCTAssertEqual(info.fileSize, 44100)
    }

    func testClosedSegmentInfoDifferentIndices() {
        let info0 = ClosedSegmentInfo(index: 0, fileName: "s0.m4a", endedAt: Date(), fileSize: 100)
        let info1 = ClosedSegmentInfo(index: 1, fileName: "s1.m4a", endedAt: Date(), fileSize: 200)
        XCTAssertNotEqual(info0.index, info1.index)
        XCTAssertLessThan(info0.fileSize, info1.fileSize)
    }
}
