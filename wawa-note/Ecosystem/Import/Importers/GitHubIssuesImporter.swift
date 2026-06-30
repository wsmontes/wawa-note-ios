import Foundation
import OSLog
import UniformTypeIdentifiers
import WawaNoteCore

struct GitHubIssuesImporter: FormatImporter {
  let formatIdentifier = "github-issues"
  let displayName = "GitHub Issues"
  let supportedUTTypes: [UTType] = [.json]

  func canRead(url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "json" else { return false }
    guard let data = try? Data(contentsOf: url) else { return false }
    return (try? JSONDecoder().decode([GitHubIssueDTO].self, from: data)) != nil
  }

  func canRead(data: Data) -> Bool {
    return (try? JSONDecoder().decode([GitHubIssueDTO].self, from: data)) != nil
  }

  func importFromURL(_ url: URL) async throws -> ImportResult {
    let data = try Data(contentsOf: url)
    let issues = try JSONDecoder().decode([GitHubIssueDTO].self, from: data)

    let item = KnowledgeItem(
      type: .note,
      title: "GitHub Issues Import (\(issues.count) issues)",
      status: .draft
    )
    item.bodyText = buildBody(for: issues)
    item.tags = buildTags(for: issues)
    item.isImported = true
    item.importSourceURL = url.absoluteString

    AppLog.general.info("Imported \(issues.count) GitHub issues into one KnowledgeItem")
    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
  }

  private func buildBody(for issues: [GitHubIssueDTO]) -> String {
    var body = "# GitHub Issues Import\n\n"
    body += "**\(issues.count) issues** imported.\n\n---\n\n"

    for issue in issues {
      body += "## #\(issue.number) \(issue.title)\n"
      body += "**State:** \(issue.state) | "
      if let assignee = issue.assignee { body += "**Assignee:** \(assignee) | " }
      if let milestone = issue.milestone { body += "**Milestone:** \(milestone) | " }
      if !issue.labels.isEmpty { body += "**Labels:** \(issue.labels.joined(separator: ", "))" }
      body += "\n\n"
      if !issue.body.isEmpty { body += "\(issue.body)\n\n" }
      if !issue.comments.isEmpty {
        body += "### Comments\n\n"
        for comment in issue.comments {
          body +=
            "> **\(comment.author)**\n> \(comment.body.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
      }
      body += "[View on GitHub](\(issue.htmlUrl))\n\n---\n\n"
    }

    return body
  }

  private func buildTags(for issues: [GitHubIssueDTO]) -> [String] {
    var tags: Set<String> = ["github"]
    for issue in issues {
      tags.insert(issue.state)
      for label in issue.labels { tags.insert(label) }
    }
    return Array(tags)
  }
}

// MARK: - GitHub API DTO

private struct GitHubIssueDTO: Decodable {
  let number: Int
  let title: String
  let state: String
  let body: String
  let htmlUrl: String
  let assignee: String?
  let milestone: String?
  let labels: [String]
  let comments: [GitHubCommentDTO]

  enum CodingKeys: String, CodingKey {
    case number, title, state, body, labels
    case htmlUrl = "html_url"
    case assignee, milestone
    case comments
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    number = try c.decode(Int.self, forKey: .number)
    title = try c.decode(String.self, forKey: .title)
    state = try c.decode(String.self, forKey: .state)
    body = (try? c.decode(String.self, forKey: .body)) ?? ""
    htmlUrl = try c.decode(String.self, forKey: .htmlUrl)

    if let userObj = try? c.decodeIfPresent(GitHubUserDTO.self, forKey: .assignee) {
      assignee = userObj.login
    } else {
      assignee = try? c.decodeIfPresent(String.self, forKey: .assignee)
    }

    if let milestoneObj = try? c.decodeIfPresent(GitHubMilestoneDTO.self, forKey: .milestone) {
      milestone = milestoneObj.title
    } else {
      milestone = try? c.decodeIfPresent(String.self, forKey: .milestone)
    }

    if let labelObjs = try? c.decodeIfPresent([GitHubLabelDTO].self, forKey: .labels) {
      labels = labelObjs.map { $0.name }
    } else {
      labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
    }

    comments = (try? c.decodeIfPresent([GitHubCommentDTO].self, forKey: .comments)) ?? []
  }
}

private struct GitHubUserDTO: Decodable {
  let login: String
}

private struct GitHubMilestoneDTO: Decodable {
  let title: String
}

private struct GitHubLabelDTO: Decodable {
  let name: String
}

private struct GitHubCommentDTO: Decodable {
  let author: String
  let body: String

  enum CodingKeys: String, CodingKey {
    case author = "user"
    case body
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let user = try? c.decodeIfPresent(GitHubUserDTO.self, forKey: .author) {
      author = user.login
    } else {
      author = "unknown"
    }
    body = (try? c.decode(String.self, forKey: .body)) ?? ""
  }
}
