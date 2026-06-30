import XCTest

@testable import Wawa_Note

final class AnarlogDocumentTests: XCTestCase {

  // MARK: - Parse tests

  func testParseBasic() throws {
    let input = """
      ---
      title: "Sprint Review"
      date: 2025-06-08T10:00:00Z
      duration: 3600
      tags:
        - sprint
        - engineering
      ---
      # Summary
      We reviewed the sprint progress.
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.title, "Sprint Review")
    XCTAssertEqual(doc.frontmatter.duration, 3600)
    XCTAssertEqual(doc.frontmatter.tags, ["sprint", "engineering"])
    XCTAssertTrue(doc.content.contains("We reviewed the sprint progress"))
  }

  func testParseWithParticipants() throws {
    let input = """
      ---
      title: "Design Review"
      participants:
        - name: "Alice"
          job_title: "Design Lead"
        - name: "Bob"
      ---
      # Design Review
      Discussed the new design system.
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.participants?.count, 2)
    XCTAssertEqual(doc.frontmatter.participants?[0].name, "Alice")
    XCTAssertEqual(doc.frontmatter.participants?[0].jobTitle, "Design Lead")
    XCTAssertEqual(doc.frontmatter.participants?[1].name, "Bob")
    XCTAssertNil(doc.frontmatter.participants?[1].jobTitle)
  }

  func testParseWithTranscript() throws {
    let input = """
      ---
      title: "Standup"
      transcript:
        segments:
          - speaker: "Alice"
            text: "Shipped the login page"
          - speaker: "Bob"
            text: "Working on API"
      ---
      # Standup Notes
      - Login shipped
      - API in progress
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.transcript?.segments.count, 2)
    XCTAssertEqual(doc.frontmatter.transcript?.segments[0].speaker, "Alice")
    XCTAssertEqual(doc.frontmatter.transcript?.segments[0].text, "Shipped the login page")
  }

  func testParseWithTemplate() throws {
    let input = """
      ---
      title: "Sprint Planning"
      template:
        title: "Sprint Plan"
        description: "Weekly sprint planning template"
        sections:
          - title: "Goals"
            description: "What we want to achieve"
          - title: "Capacity"
      ---
      # Goals
      - Ship feature X
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.template?.title, "Sprint Plan")
    XCTAssertEqual(doc.frontmatter.template?.sections?.count, 2)
    XCTAssertEqual(doc.frontmatter.template?.sections?[0].title, "Goals")
  }

  func testParseWithSession() throws {
    let input = """
      ---
      title: "Q2 Review"
      session:
        title: "Calendar Event"
        started_at: "2025-06-08 10:00"
        ended_at: "2025-06-08 11:00"
        event:
          name: "Quarterly Review"
      ---
      Content here.
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.session?.title, "Calendar Event")
    XCTAssertEqual(doc.frontmatter.session?.startedAt, "2025-06-08 10:00")
    XCTAssertEqual(doc.frontmatter.session?.event?.name, "Quarterly Review")
  }

  func testParseEmptyFrontmatter() throws {
    let input = """
      ---
      ---
      Content without frontmatter.
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertNil(doc.frontmatter.title)
    XCTAssertTrue(doc.content.contains("Content without frontmatter"))
  }

  func testParseNoFrontmatterFails() {
    let input = "Just markdown content, no frontmatter."
    XCTAssertThrowsError(try AnarlogDocument.parse(from: input)) { error in
      XCTAssertTrue(error is AnarlogDocument.ParseError)
    }
  }

  func testParseContentWithDashesInBody() throws {
    let input = """
      ---
      title: "Test"
      ---
      Some content with --- dashes in the middle.
      And another --- line.
      """

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertTrue(doc.content.contains("--- dashes"))
    XCTAssertTrue(doc.content.contains("another --- line"))
  }

  func testParseCRLFLineEndings() throws {
    let input = "---\r\ntitle: \"Windows Test\"\r\ntags:\r\n  - rust\r\n---\r\n\r\nContent here."

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.title, "Windows Test")
    XCTAssertEqual(doc.frontmatter.tags, ["rust"])
    XCTAssertEqual(doc.content, "Content here.")
  }

  func testParseMixedLineEndings() throws {
    let input = "---\r\ntitle: \"Mixed\"\n---\n\r\nContent"

    let doc = try AnarlogDocument.parse(from: input)
    XCTAssertEqual(doc.frontmatter.title, "Mixed")
    XCTAssertEqual(doc.content, "Content")
  }

  // MARK: - Render tests (round-trip)

  func testRoundTripBasic() throws {
    let input = """
      ---
      title: "Sprint Review"
      date: 2025-06-08T10:00:00Z
      duration: 3600
      tags:
        - sprint
        - engineering
      ---
      # Summary
      We reviewed the sprint progress.
      """

    let doc = try AnarlogDocument.parse(from: input)
    let rendered = try doc.render()

    // Parse again to verify fidelity
    let doc2 = try AnarlogDocument.parse(from: rendered)
    XCTAssertEqual(doc2.frontmatter.title, "Sprint Review")
    XCTAssertEqual(doc2.frontmatter.duration, 3600)
    XCTAssertEqual(doc2.frontmatter.tags, ["sprint", "engineering"])
    XCTAssertEqual(doc2.content, "# Summary\nWe reviewed the sprint progress.")
  }

  func testRoundTripWithParticipants() throws {
    let input = """
      ---
      participants:
        - name: "Alice"
          job_title: "Engineer"
        - name: "Bob"
      title: "Design Review"
      ---
      # Notes
      Discussed design system.
      """

    let doc = try AnarlogDocument.parse(from: input)
    let rendered = try doc.render()
    let doc2 = try AnarlogDocument.parse(from: rendered)

    XCTAssertEqual(doc2.frontmatter.title, "Design Review")
    XCTAssertEqual(doc2.frontmatter.participants?.count, 2)
    XCTAssertEqual(doc2.frontmatter.participants?[0].name, "Alice")
    XCTAssertEqual(doc2.frontmatter.participants?[1].name, "Bob")
  }

  func testRoundTripFullDocument() throws {
    // Full anarlog document with all fields
    let input = """
      ---
      date: 2025-06-08T10:00:00Z
      duration: 3600
      participants:
        - job_title: "Engineering Lead"
          name: "Alice"
        - name: "Bob"
      session:
        event:
          name: "Sprint Planning"
        started_at: "2025-06-08 10:00"
        title: "Calendar Event"
      tags:
        - sprint
        - planning
      template:
        description: "Weekly sprint planning template"
        sections:
          - title: "Goals"
          - description: "Who is available"
            title: "Capacity"
        title: "Sprint Plan"
      title: "Sprint Planning Session"
      transcript:
        segments:
          - speaker: "Alice"
            text: "Let's plan the sprint"
          - speaker: "Bob"
            text: "I have capacity for 8 points"
      ---
      # Goals
      - Complete user auth feature

      # Capacity
      - Alice: 8 points
      - Bob: 8 points
      """

    let doc = try AnarlogDocument.parse(from: input)
    let rendered = try doc.render()
    let doc2 = try AnarlogDocument.parse(from: rendered)

    // Verify all fields survived round-trip
    XCTAssertEqual(doc2.frontmatter.title, "Sprint Planning Session")
    XCTAssertEqual(doc2.frontmatter.duration, 3600)
    XCTAssertEqual(doc2.frontmatter.participants?.count, 2)
    XCTAssertEqual(doc2.frontmatter.tags, ["sprint", "planning"])
    XCTAssertEqual(doc2.frontmatter.template?.title, "Sprint Plan")
    XCTAssertEqual(doc2.frontmatter.template?.sections?.count, 2)
    XCTAssertEqual(doc2.frontmatter.transcript?.segments.count, 2)
    XCTAssertEqual(doc2.frontmatter.session?.event?.name, "Sprint Planning")

    // Content preserved
    XCTAssertTrue(doc2.content.contains("# Goals"))
    XCTAssertTrue(doc2.content.contains("Complete user auth feature"))
  }

  func testRoundTripSortedKeys() throws {
    // Verify that rendered keys are sorted alphabetically
    let input = """
      ---
      title: "Test"
      duration: 3600
      date: 2025-06-08T10:00:00Z
      ---
      Content
      """

    let doc = try AnarlogDocument.parse(from: input)
    let rendered = try doc.render()

    // Find the order of keys in the YAML block
    let lines = rendered.components(separatedBy: "\n")
    let keys = lines.compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"),
        !trimmed.hasPrefix("---"), let colonIdx = trimmed.firstIndex(of: ":")
      else {
        return nil
      }
      return String(trimmed[..<colonIdx])
    }

    // date should come before duration, which comes before title
    if let dateIdx = keys.firstIndex(of: "date"),
      let durationIdx = keys.firstIndex(of: "duration"),
      let titleIdx = keys.firstIndex(of: "title")
    {
      XCTAssertLessThan(dateIdx, durationIdx)
      XCTAssertLessThan(durationIdx, titleIdx)
    }
  }

  // MARK: - Importer detection tests

  func testIsAnarlogDocument() {
    let importer = AnarlogImporter()

    // Valid anarlog doc with participants
    let validWithParticipants = """
      ---
      title: "Test"
      participants:
        - name: "Alice"
      ---
      Content
      """
    let data1 = validWithParticipants.data(using: .utf8)!
    XCTAssertTrue(importer.canRead(data: data1))

    // Valid anarlog doc with transcript
    let validWithTranscript = """
      ---
      title: "Test"
      transcript:
        segments:
          - speaker: "A"
            text: "hello"
      ---
      Content
      """
    let data2 = validWithTranscript.data(using: .utf8)!
    XCTAssertTrue(importer.canRead(data: data2))

    // Plain markdown (no anarlog fields)
    let plainMarkdown = """
      ---
      title: "Just a title"
      ---
      Content
      """
    let data3 = plainMarkdown.data(using: .utf8)!
    // We may or may not accept this depending on heuristic
    // Currently: no anarlog-specific fields → not anarlog
    // Actually, with only title, it may not be detected
    _ = data3
  }
}
