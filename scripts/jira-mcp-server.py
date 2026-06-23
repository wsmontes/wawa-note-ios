#!/usr/bin/env python3
"""
Jira MCP Server — exposes Jira operations as Claude tools via Model Context Protocol.
No external dependencies. Uses only Python stdlib + the existing jira-cli.py backend.

Usage: Add to ~/.claude/claude-code.json or ~/.claude.json as an MCP server:
{
  "mcpServers": {
    "jira": {
      "command": "python3",
      "args": ["/path/to/scripts/jira-mcp-server.py"],
      "env": {
        "JIRA_URL": "https://wawasoftbc.atlassian.net",
        "JIRA_EMAIL": "wawasoftbc@gmail.com",
        "JIRA_TOKEN": "your-token"
      }
    }
  }
}
"""

import json, sys, os, subprocess, textwrap

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
JIRA_CLI = os.path.join(SCRIPT_DIR, "jira-cli.py")

# ============================================================
# MCP Protocol (JSON-RPC 2.0 over stdio)
# ============================================================

def log(msg: str):
    """Write to stderr for MCP logging (stdout is the protocol channel)."""
    print(f"[jira-mcp] {msg}", file=sys.stderr, flush=True)

def send_response(request_id, result):
    """Send a JSON-RPC response."""
    msg = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

def send_error(request_id, code: int, message: str):
    """Send a JSON-RPC error."""
    msg = json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

# ============================================================
# Jira CLI wrapper
# ============================================================

def run_jira(*args: str) -> dict:
    """Run jira-cli.py with given args and return parsed result."""
    try:
        result = subprocess.run(
            [sys.executable, JIRA_CLI] + list(args),
            capture_output=True, text=True, timeout=30,
            cwd=SCRIPT_DIR
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            return {"ok": False, "error": result.stderr.strip() or output}
        return {"ok": True, "output": output}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Jira CLI timed out after 30s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}

# ============================================================
# Tool definitions
# ============================================================

TOOLS = [
    {
        "name": "jira_search",
        "description": "Search Jira issues. Returns matching issues with key, summary, status, priority, labels.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Text to search for in issues"},
                "project": {"type": "string", "description": "Project key (default: KAN)"},
                "status": {"type": "string", "description": "Filter by status: 'To Do', 'In Progress', 'In Review', 'Done'"},
                "assignee": {"type": "string", "description": "Filter by assignee (username or 'me')"},
                "maxResults": {"type": "integer", "description": "Max results (default: 50)"},
            },
            "required": []
        }
    },
    {
        "name": "jira_get_issue",
        "description": "Get full details of a single Jira issue including description, comments, and linked issues.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Issue key (e.g., KAN-34)"},
                "includeComments": {"type": "boolean", "description": "Include comments (default: true)"},
                "includeLinks": {"type": "boolean", "description": "Include linked issues (default: true)"},
            },
            "required": ["key"]
        }
    },
    {
        "name": "jira_move_issue",
        "description": "Transition a Jira issue to a new status (To Do, In Progress, In Review, Done).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Issue key (e.g., KAN-34)"},
                "status": {"type": "string", "description": "Target status: 'To Do', 'In Progress', 'In Review', 'Done'"},
            },
            "required": ["key", "status"]
        }
    },
    {
        "name": "jira_comment",
        "description": "Add a comment to a Jira issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Issue key (e.g., KAN-34)"},
                "body": {"type": "string", "description": "Comment text (markdown supported)"},
            },
            "required": ["key", "body"]
        }
    },
    {
        "name": "jira_create_issue",
        "description": "Create a new Jira issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description": "Project key (default: KAN)"},
                "summary": {"type": "string", "description": "Issue title"},
                "description": {"type": "string", "description": "Issue description (markdown supported)"},
                "type": {"type": "string", "description": "Issue type: 'Bug', 'Feature', 'Epic', 'Task', 'Sub-task' (default: Task)"},
                "priority": {"type": "string", "description": "Priority: 'Highest', 'High', 'Medium', 'Low', 'Lowest' (default: Medium)"},
                "parent": {"type": "string", "description": "Parent issue key (for sub-tasks)"},
                "labels": {"type": "string", "description": "Comma-separated labels"},
            },
            "required": ["summary"]
        }
    },
    {
        "name": "jira_my_issues",
        "description": "List all open issues assigned to me, across all projects.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "jira_assign",
        "description": "Assign a Jira issue to a user (use 'me' for self).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Issue key (e.g., KAN-34)"},
                "user": {"type": "string", "description": "Username or 'me' to assign to yourself"},
            },
            "required": ["key", "user"]
        }
    },
    {
        "name": "jira_sprint",
        "description": "View the current sprint board for a project, grouped by status.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description": "Project key (default: KAN)"},
                "assignee": {"type": "string", "description": "Filter by assignee"},
            },
            "required": []
        }
    },
]

# ============================================================
# Tool execution
# ============================================================

def execute_tool(name: str, arguments: dict) -> str:
    """Execute a tool and return the result string."""
    if name == "jira_search":
        args = ["search", arguments.get("query", "")]
        if arguments.get("project"): args += ["--project", arguments["project"]]
        if arguments.get("status"): args += ["--status", arguments["status"]]
        if arguments.get("assignee"): args += ["--assignee", arguments["assignee"]]
        result = run_jira(*args)
        return result.get("output") or result.get("error", "No results")

    elif name == "jira_get_issue":
        args = ["show", arguments["key"]]
        if arguments.get("includeComments", True): args.append("--comments")
        if arguments.get("includeLinks", True): args.append("--links")
        result = run_jira(*args)
        return result.get("output") or result.get("error", "Issue not found")

    elif name == "jira_move_issue":
        result = run_jira("move", arguments["key"], arguments["status"])
        return result.get("output") or result.get("error", "Move failed")

    elif name == "jira_comment":
        result = run_jira("comment", arguments["key"], arguments["body"])
        return result.get("output") or result.get("error", "Comment failed")

    elif name == "jira_create_issue":
        args = ["create", arguments.get("project", "KAN"), arguments["summary"]]
        if arguments.get("type"): args += ["--type", arguments["type"]]
        if arguments.get("priority"): args += ["--priority", arguments["priority"]]
        if arguments.get("parent"): args += ["--parent", arguments["parent"]]
        if arguments.get("labels"): args += ["--labels", arguments["labels"]]
        if arguments.get("description"):
            args += ["--description", arguments["description"]]
        result = run_jira(*args)
        return result.get("output") or result.get("error", "Create failed")

    elif name == "jira_my_issues":
        result = run_jira("mine")
        return result.get("output") or result.get("error", "No issues")

    elif name == "jira_assign":
        result = run_jira("assign", arguments["key"], arguments["user"])
        return result.get("output") or result.get("error", "Assign failed")

    elif name == "jira_sprint":
        args = ["sprint"]
        if arguments.get("project"): args.append(arguments["project"])
        if arguments.get("assignee"): args += ["--assignee", arguments["assignee"]]
        result = run_jira(*args)
        return result.get("output") or result.get("error", "Sprint query failed")

    return f"Unknown tool: {name}"

# ============================================================
# Main loop — MCP stdio server
# ============================================================

def main():
    log("Jira MCP Server starting...")

    # Read init message
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"Invalid JSON: {e}")
            continue

        request_id = request.get("id")
        method = request.get("method", "")
        params = request.get("params", {})

        if method == "initialize":
            log("Received initialize request")
            send_response(request_id, {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "jira-mcp-server", "version": "1.0.0"},
                "capabilities": {"tools": {}}
            })

        elif method == "notifications/initialized":
            log("Client initialized")

        elif method == "tools/list":
            send_response(request_id, {"tools": TOOLS})

        elif method == "tools/call":
            tool_name = params.get("name", "")
            tool_args = params.get("arguments", {})
            log(f"Calling tool: {tool_name}({tool_args})")
            result_text = execute_tool(tool_name, tool_args)
            send_response(request_id, {
                "content": [{"type": "text", "text": result_text}]
            })

        elif method == "ping":
            send_response(request_id, {})

        else:
            log(f"Unknown method: {method}")
            send_error(request_id, -32601, f"Method not found: {method}")

    log("Jira MCP Server stopped.")

if __name__ == "__main__":
    main()
