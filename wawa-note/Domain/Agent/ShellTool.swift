import Foundation

/// The single agent tool — a virtual filesystem shell.
/// Replaces 47 individual tools with one `run_command` that the LLM
/// already knows how to use (ls, cd, cat, find, grep, touch, echo, rm, mv, ...).
struct ShellTool: AgentTool {
  let name = "run_command"
  let description = """
    Run a shell command on the virtual knowledge filesystem.
    Start with 'ls /' to see the workspace overview.
    """
  let parameters = AIToolParameters(
    properties: [
      "command": AIToolProperty(
        type: "string",
        description:
          "Shell command: ls, cd, cat, find, grep, touch, echo '...' > path, rm, mv, head, wc, history"
      )
    ],
    required: ["command"]
  )

  @MainActor
  func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
  {
    let command = (arguments["command"] as? String) ?? ""
    guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
      return ToolResult(
        content: "Usage: run_command with a shell command. Try 'ls /' to start.",
        citations: [],
        isError: true,
        displaySummary: "Empty command"
      )
    }
    return ShellInterpreter.execute(command: command, context: context)
  }
}
