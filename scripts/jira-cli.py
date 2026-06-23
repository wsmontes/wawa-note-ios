#!/usr/bin/env python3
"""
jira-cli.py — Full-featured JIRA Cloud CLI for wawa-note-ios project.
Reads configuration from .env file. Supports all read/write operations.

Usage:
    python jira-cli.py <command> [args] [--options]

Commands:
    show <key>              Show issue details (--comments --links)
    search <text>           Search issues (--project --assignee --status --type --labels)
    jql <query>             Raw JQL query
    mine                    My open issues
    recent [project]        Recent issues
    children <key>          Sub-tasks of an issue
    create <project> <summary>  Create issue (--type --priority --assignee --labels --description --parent)
    update <key>            Update issue fields (--summary --priority --assignee --labels --description)
    move <key> <status>     Transition issue to status
    assign <key> <user>     Assign issue
    comment <key> <body>    Add comment
    link <from> <to>        Link issues (--type)
    label <key> add|remove <labels>  Manage labels
    sprint [project]        Sprint board view (--assignee --name)
    fields <project>        Show available issue types
    users <query>           Search users
    transitions <key>       Show available transitions
    attachments <key>       List attachments
    projects                List all projects
    me                      Show current user info
"""
import os
import sys
import json
import shlex
import argparse
import requests
import urllib3
from pathlib import Path
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def load_env():
    """Load .env from script directory or current directory."""
    for p in [Path(__file__).parent / '.env', Path.cwd() / '.env']:
        if p.exists():
            for line in p.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    os.environ.setdefault(k.strip(), v.strip())
            return
    print("WARNING: No .env file found", file=sys.stderr)


load_env()

JIRA_URL = os.environ.get('JIRA_URL', '').rstrip('/')
JIRA_EMAIL = os.environ.get('JIRA_EMAIL', '')
JIRA_TOKEN = os.environ.get('JIRA_TOKEN', '')
JIRA_PROJECT = os.environ.get('JIRA_PROJECT', 'KAN')


class JiraAPI:
    """Low-level JIRA Cloud REST API v3 client."""

    def __init__(self):
        self.base = f"{JIRA_URL}/rest/api/3"
        self.session = requests.Session()
        self.session.auth = HTTPBasicAuth(JIRA_EMAIL, JIRA_TOKEN)
        self.session.verify = False
        self.session.headers.update({
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        })

    def get(self, path, params=None):
        return self.session.get(f"{self.base}{path}", params=params, timeout=30)

    def post(self, path, payload):
        return self.session.post(f"{self.base}{path}", json=payload, timeout=30)

    def put(self, path, payload):
        return self.session.put(f"{self.base}{path}", json=payload, timeout=30)

    def delete(self, path):
        return self.session.delete(f"{self.base}{path}", timeout=30)

    def adf(self, text):
        """Convert plain text to Atlassian Document Format."""
        return {
            "type": "doc", "version": 1,
            "content": [{"type": "paragraph", "content": [{"type": "text", "text": text}]}]
        }

    def adf_to_text(self, node):
        """Convert ADF to plain text."""
        if not node:
            return ""
        if isinstance(node, str):
            return node
        if node.get("type") == "text":
            return node.get("text", "")
        parts = []
        for child in node.get("content", []):
            parts.append(self.adf_to_text(child))
        return " ".join(p for p in parts if p)



    # ═══════════════════════════════════════════════════════════════════════════
    # READ OPERATIONS
    # ═══════════════════════════════════════════════════════════════════════════

    def search_jql(self, jql, max_results=20, fields=None):
        """Execute JQL search via POST (Cloud v3 requires this)."""
        payload = {
            "jql": jql,
            "maxResults": max_results,
            "fields": fields or ["summary", "status", "priority", "assignee", "issuetype", "updated", "parent", "labels", "created"]
        }
        r = self.post("/search/jql", payload)
        if r.status_code == 200:
            data = r.json()
            return {"ok": True, "issues": [self._summarize(i) for i in data.get("issues", [])], "total": data.get("total", 0)}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:200]}"}

    def get_issue(self, key):
        """Get full issue details."""
        r = self.get(f"/issue/{key}")
        if r.status_code == 200:
            return {"ok": True, "issue": self._format_full(r.json())}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:200]}"}

    def get_comments(self, key):
        r = self.get(f"/issue/{key}/comment")
        if r.status_code == 200:
            return {"ok": True, "comments": [
                {"id": c["id"], "author": c.get("author", {}).get("displayName", ""),
                 "body": self.adf_to_text(c.get("body")), "created": c.get("created", "")[:16]}
                for c in r.json().get("comments", [])
            ]}
        return {"ok": False, "error": f"{r.status_code}"}

    def get_links(self, key):
        r = self.get(f"/issue/{key}", {"fields": "issuelinks"})
        if r.status_code != 200:
            return {"ok": False, "error": f"{r.status_code}"}
        links = []
        for link in r.json().get("fields", {}).get("issuelinks", []):
            if "outwardIssue" in link:
                target = link["outwardIssue"]
                direction = link.get("type", {}).get("outward", "relates to")
            elif "inwardIssue" in link:
                target = link["inwardIssue"]
                direction = link.get("type", {}).get("inward", "relates to")
            else:
                continue
            links.append({"key": target.get("key"), "direction": direction,
                         "summary": target.get("fields", {}).get("summary", "")})
        return {"ok": True, "links": links}

    def get_transitions(self, key):
        r = self.get(f"/issue/{key}/transitions")
        if r.status_code == 200:
            return {"ok": True, "transitions": [{"id": t["id"], "name": t["name"]} for t in r.json().get("transitions", [])]}
        return {"ok": False, "error": f"{r.status_code}"}

    def get_attachments(self, key):
        r = self.get(f"/issue/{key}", {"fields": "attachment"})
        if r.status_code != 200:
            return {"ok": False, "error": f"{r.status_code}"}
        return {"ok": True, "attachments": [
            {"filename": a.get("filename"), "size": a.get("size"), "created": a.get("created", "")[:16]}
            for a in r.json().get("fields", {}).get("attachment", [])
        ]}

    def list_projects(self):
        r = self.get("/project")
        if r.status_code == 200:
            return {"ok": True, "projects": [{"key": p["key"], "name": p["name"], "id": p["id"]} for p in r.json()]}
        return {"ok": False, "error": f"{r.status_code}"}

    def get_myself(self):
        r = self.get("/myself")
        if r.status_code == 200:
            u = r.json()
            return {"ok": True, "accountId": u.get("accountId"), "displayName": u.get("displayName"), "email": u.get("emailAddress")}
        return {"ok": False, "error": f"{r.status_code}"}

    def search_users(self, query):
        r = self.get("/user/search", {"query": query, "maxResults": 10})
        if r.status_code == 200:
            return {"ok": True, "users": [{"accountId": u.get("accountId"), "displayName": u.get("displayName")} for u in r.json()]}
        return {"ok": False, "error": f"{r.status_code}"}

    def get_fields(self, project_key):
        r = self.get(f"/issue/createmeta/{project_key}/issuetypes")
        if r.status_code == 200:
            types = r.json().get("issueTypes", r.json().get("values", []))
            return {"ok": True, "issue_types": [{"name": t["name"], "id": t["id"]} for t in types]}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:200]}"}



    # ═══════════════════════════════════════════════════════════════════════════
    # WRITE OPERATIONS
    # ═══════════════════════════════════════════════════════════════════════════

    def create_issue(self, project, summary, issue_type="Task", priority=None,
                     assignee=None, labels=None, description=None, parent=None):
        fields = {
            "project": {"key": project},
            "summary": summary,
            "issuetype": {"name": issue_type},
        }
        if priority:
            fields["priority"] = {"name": priority}
        if assignee:
            resolved = self._resolve_user(assignee)
            if resolved:
                fields["assignee"] = {"accountId": resolved}
        if labels:
            fields["labels"] = labels
        if description:
            fields["description"] = self.adf(description)
        if parent:
            fields["parent"] = {"key": parent}

        r = self.post("/issue", {"fields": fields})
        if r.status_code == 201:
            data = r.json()
            return {"ok": True, "key": data["key"], "url": f"{JIRA_URL}/browse/{data['key']}"}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:300]}"}

    def update_issue(self, key, summary=None, priority=None, assignee=None,
                     labels_add=None, labels_remove=None, description=None):
        fields = {}
        update = {}
        if summary:
            fields["summary"] = summary
        if priority:
            fields["priority"] = {"name": priority}
        if assignee:
            resolved = self._resolve_user(assignee)
            if resolved:
                fields["assignee"] = {"accountId": resolved}
        if description:
            fields["description"] = self.adf(description)
        if labels_add:
            update["labels"] = [{"add": l} for l in labels_add]
        if labels_remove:
            update.setdefault("labels", []).extend([{"remove": l} for l in labels_remove])

        payload = {}
        if fields:
            payload["fields"] = fields
        if update:
            payload["update"] = update

        r = self.put(f"/issue/{key}", payload)
        if r.status_code == 204:
            return {"ok": True}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:200]}"}

    def add_comment(self, key, body):
        r = self.post(f"/issue/{key}/comment", {"body": self.adf(body)})
        if r.status_code == 201:
            return {"ok": True, "id": r.json().get("id")}
        return {"ok": False, "error": f"{r.status_code}: {r.text[:200]}"}

    def transition_issue(self, key, status_name):
        """Fuzzy-match status name to available transition and execute."""
        trans = self.get_transitions(key)
        if not trans.get("ok"):
            return trans
        target = status_name.lower().strip()
        for t in trans["transitions"]:
            if t["name"].lower() == target:
                r = self.post(f"/issue/{key}/transitions", {"transition": {"id": t["id"]}})
                return {"ok": r.status_code == 204, "to": t["name"]}
        # Substring match
        for t in trans["transitions"]:
            if target in t["name"].lower():
                r = self.post(f"/issue/{key}/transitions", {"transition": {"id": t["id"]}})
                return {"ok": r.status_code == 204, "to": t["name"]}
        return {"ok": False, "error": f"No transition matching '{status_name}'", "available": [t["name"] for t in trans["transitions"]]}

    def assign_issue(self, key, user):
        resolved = self._resolve_user(user)
        if not resolved:
            return {"ok": False, "error": f"User '{user}' not found"}
        r = self.put(f"/issue/{key}", {"fields": {"assignee": {"accountId": resolved}}})
        return {"ok": r.status_code == 204}

    def link_issues(self, from_key, to_key, link_type="Relates"):
        r = self.post("/issueLink", {
            "type": {"name": link_type},
            "inwardIssue": {"key": from_key},
            "outwardIssue": {"key": to_key}
        })
        return {"ok": r.status_code in (200, 201, 204)}

    def delete_issue(self, key):
        r = self.delete(f"/issue/{key}")
        return {"ok": r.status_code == 204}



    # ═══════════════════════════════════════════════════════════════════════════
    # HELPERS
    # ═══════════════════════════════════════════════════════════════════════════

    def _resolve_user(self, name):
        """Resolve display name to accountId."""
        r = self.get("/user/search", {"query": name, "maxResults": 5})
        if r.status_code == 200:
            users = r.json()
            if users:
                # Prefer exact match
                for u in users:
                    if u.get("displayName", "").lower() == name.lower():
                        return u["accountId"]
                return users[0]["accountId"]
        return None

    def _summarize(self, raw):
        """Summarize an issue from search results."""
        f = raw.get("fields", {})
        return {
            "key": raw.get("key"),
            "type": f.get("issuetype", {}).get("name", ""),
            "summary": f.get("summary", ""),
            "status": f.get("status", {}).get("name", ""),
            "priority": f.get("priority", {}).get("name", "") if f.get("priority") else "",
            "assignee": f.get("assignee", {}).get("displayName", "Unassigned") if f.get("assignee") else "Unassigned",
            "labels": f.get("labels", []),
            "updated": (f.get("updated") or "")[:16],
            "parent": f.get("parent", {}).get("key") if f.get("parent") else None,
        }

    def _format_full(self, raw):
        """Format full issue details."""
        f = raw.get("fields", {})
        return {
            "key": raw.get("key"),
            "summary": f.get("summary", ""),
            "description": self.adf_to_text(f.get("description")),
            "status": f.get("status", {}).get("name", ""),
            "priority": f.get("priority", {}).get("name", "") if f.get("priority") else "",
            "type": f.get("issuetype", {}).get("name", ""),
            "assignee": f.get("assignee", {}).get("displayName", "Unassigned") if f.get("assignee") else "Unassigned",
            "reporter": f.get("reporter", {}).get("displayName", "") if f.get("reporter") else "",
            "labels": f.get("labels", []),
            "created": (f.get("created") or "")[:16],
            "updated": (f.get("updated") or "")[:16],
            "parent": f.get("parent", {}).get("key") if f.get("parent") else None,
        }




# ═══════════════════════════════════════════════════════════════════════════════
# CLI COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

def fmt(data, indent=2):
    """Pretty-print JSON output."""
    print(json.dumps(data, indent=indent, ensure_ascii=False))


def cmd_show(api, args):
    result = api.get_issue(args.key)
    if not result["ok"]:
        fmt(result); return
    fmt(result["issue"])
    if args.comments:
        comments = api.get_comments(args.key)
        if comments["ok"] and comments["comments"]:
            print(f"\n--- Comments ({len(comments['comments'])}) ---")
            for c in comments["comments"]:
                print(f"  [{c['created']}] {c['author']}: {c['body'][:200]}")
    if args.links:
        links = api.get_links(args.key)
        if links["ok"] and links["links"]:
            print(f"\n--- Links ({len(links['links'])}) ---")
            for l in links["links"]:
                print(f"  {l['direction']} {l['key']}: {l['summary']}")


def cmd_search(api, args):
    parts = []
    project = args.project or JIRA_PROJECT
    if project:
        parts.append(f"project = {project}")
    if args.assignee:
        parts.append(f'assignee = "{args.assignee}"')
    if args.status:
        s = args.status.lower()
        if s in ("open", "active"):
            parts.append("status != Done")
        else:
            parts.append(f'status = "{args.status}"')
    if args.type:
        parts.append(f'issuetype = "{args.type}"')
    if args.labels:
        for l in args.labels.split(","):
            parts.append(f'labels = "{l.strip()}"')
    if args.text:
        safe = args.text.replace('"', '\\"')
        parts.append(f'text ~ "{safe}"')
    jql = " AND ".join(parts) + " ORDER BY updated DESC" if parts else "ORDER BY updated DESC"
    result = api.search_jql(jql, args.max)
    if result["ok"]:
        for i in result["issues"]:
            labels = f" [{','.join(i['labels'][:3])}]" if i['labels'] else ""
            print(f"  {i['key']:8} {i['status']:12} {i['priority']:8} {i['summary'][:55]}{labels}")
        print(f"\n  ({result['total']} total)")
    else:
        fmt(result)


def cmd_jql(api, args):
    result = api.search_jql(args.query, args.max)
    if result["ok"]:
        for i in result["issues"]:
            print(f"  {i['key']:8} {i['status']:12} {i['type']:8} {i['summary'][:55]}")
        print(f"\n  ({result['total']} total)")
    else:
        fmt(result)


def cmd_mine(api, args):
    result = api.search_jql(f"project = {JIRA_PROJECT} AND assignee = currentUser() AND status != Done ORDER BY priority ASC", 30)
    if result["ok"]:
        if not result["issues"]:
            print("  No open issues assigned to you.")
        for i in result["issues"]:
            print(f"  {i['key']:8} {i['status']:12} {i['priority']:8} {i['summary'][:55]}")
    else:
        fmt(result)


def cmd_recent(api, args):
    project = args.project or JIRA_PROJECT
    result = api.search_jql(f"project = {project} ORDER BY updated DESC", args.max)
    if result["ok"]:
        for i in result["issues"]:
            print(f"  {i['key']:8} {i['status']:12} {i['updated']} {i['summary'][:50]}")
    else:
        fmt(result)


def cmd_children(api, args):
    result = api.search_jql(f"parent = {args.key} ORDER BY created ASC", 50)
    if result["ok"]:
        for i in result["issues"]:
            print(f"  {i['key']:8} {i['status']:12} {i['type']:8} {i['summary'][:50]}")
    else:
        fmt(result)


def cmd_create(api, args):
    result = api.create_issue(
        project=args.project or JIRA_PROJECT,
        summary=args.summary,
        issue_type=args.type or "Task",
        priority=args.priority,
        assignee=args.assignee,
        labels=[l.strip() for l in args.labels.split(",")] if args.labels else None,
        description=args.description,
        parent=args.parent,
    )
    if result["ok"]:
        print(f"  Created: {result['key']} — {result['url']}")
    else:
        fmt(result)


def cmd_update(api, args):
    result = api.update_issue(
        key=args.key,
        summary=args.summary,
        priority=args.priority,
        assignee=args.assignee,
        labels_add=[l.strip() for l in args.add_labels.split(",")] if args.add_labels else None,
        labels_remove=[l.strip() for l in args.remove_labels.split(",")] if args.remove_labels else None,
        description=args.description,
    )
    print(f"  {'Updated' if result['ok'] else 'Failed'}: {args.key}", result.get("error", ""))


def cmd_move(api, args):
    result = api.transition_issue(args.key, args.status)
    if result["ok"]:
        print(f"  {args.key} -> {result['to']}")
    else:
        print(f"  Failed: {result.get('error', '')}")
        if result.get("available"):
            print(f"  Available: {', '.join(result['available'])}")


def cmd_assign(api, args):
    result = api.assign_issue(args.key, args.user)
    print(f"  {'Assigned' if result['ok'] else 'Failed'}: {args.key} -> {args.user}")


def cmd_comment(api, args):
    result = api.add_comment(args.key, args.body)
    if result["ok"]:
        print(f"  Comment added to {args.key} (id={result['id']})")
    else:
        fmt(result)


def cmd_link(api, args):
    result = api.link_issues(args.from_key, args.to_key, args.type)
    print(f"  {'Linked' if result['ok'] else 'Failed'}: {args.from_key} {args.type} {args.to_key}")


def cmd_label(api, args):
    if args.action == "add":
        labels = [l.strip() for l in args.labels.split(",")]
        result = api.update_issue(args.key, labels_add=labels)
    elif args.action == "remove":
        labels = [l.strip() for l in args.labels.split(",")]
        result = api.update_issue(args.key, labels_remove=labels)
    else:
        print("  Action must be 'add' or 'remove'"); return
    print(f"  {'Done' if result['ok'] else 'Failed'}: {args.action} labels on {args.key}")


def cmd_sprint(api, args):
    project = args.project or JIRA_PROJECT
    jql = f"project = {project} AND sprint in openSprints() ORDER BY status ASC, priority DESC"
    result = api.search_jql(jql, 50)
    if result["ok"]:
        by_status = {}
        for i in result["issues"]:
            by_status.setdefault(i["status"], []).append(i)
        for status, issues in by_status.items():
            print(f"\n  [{status}] ({len(issues)})")
            for i in issues:
                print(f"    {i['key']:8} {i['priority']:8} {i['summary'][:50]}")
    else:
        fmt(result)


def cmd_fields(api, args):
    result = api.get_fields(args.project or JIRA_PROJECT)
    if result["ok"]:
        for t in result["issue_types"]:
            print(f"  {t['name']:20} id={t['id']}")
    else:
        fmt(result)


def cmd_users(api, args):
    result = api.search_users(args.query)
    if result["ok"]:
        for u in result["users"]:
            print(f"  {u['displayName']:30} id={u['accountId'][:12]}...")
    else:
        fmt(result)


def cmd_transitions(api, args):
    result = api.get_transitions(args.key)
    if result["ok"]:
        for t in result["transitions"]:
            print(f"  {t['name']:20} id={t['id']}")
    else:
        fmt(result)


def cmd_attachments(api, args):
    result = api.get_attachments(args.key)
    if result["ok"]:
        for a in result["attachments"]:
            print(f"  {a['filename']:40} {a['size']:>8} bytes  {a['created']}")
    else:
        fmt(result)


def cmd_projects(api, args):
    result = api.list_projects()
    if result["ok"]:
        for p in result["projects"]:
            print(f"  {p['key']:10} {p['name']}")
    else:
        fmt(result)


def cmd_me(api, args):
    result = api.get_myself()
    if result["ok"]:
        print(f"  {result['displayName']} ({result['email']})")
        print(f"  Account ID: {result['accountId']}")
    else:
        fmt(result)




# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSER
# ═══════════════════════════════════════════════════════════════════════════════

def build_parser():
    parser = argparse.ArgumentParser(prog="jira-cli", description="JIRA Cloud CLI for wawa-note-ios")
    sub = parser.add_subparsers(dest="command")

    # show
    p = sub.add_parser("show", help="Show issue details")
    p.add_argument("key")
    p.add_argument("--comments", "-c", action="store_true")
    p.add_argument("--links", "-l", action="store_true")

    # search
    p = sub.add_parser("search", help="Search issues")
    p.add_argument("text", nargs="?", default="")
    p.add_argument("--project", "-p")
    p.add_argument("--assignee", "-a")
    p.add_argument("--status", "-s")
    p.add_argument("--type", "-t")
    p.add_argument("--labels")
    p.add_argument("--max", "-n", type=int, default=20)

    # jql
    p = sub.add_parser("jql", help="Raw JQL query")
    p.add_argument("query")
    p.add_argument("--max", "-n", type=int, default=20)

    # mine
    sub.add_parser("mine", help="My open issues")

    # recent
    p = sub.add_parser("recent", help="Recent issues")
    p.add_argument("project", nargs="?")
    p.add_argument("--max", "-n", type=int, default=10)

    # children
    p = sub.add_parser("children", help="Sub-tasks of an issue")
    p.add_argument("key")

    # create
    p = sub.add_parser("create", help="Create issue")
    p.add_argument("summary")
    p.add_argument("--project", "-p")
    p.add_argument("--type", "-t")
    p.add_argument("--priority")
    p.add_argument("--assignee", "-a")
    p.add_argument("--labels")
    p.add_argument("--description", "-d")
    p.add_argument("--parent")

    # update
    p = sub.add_parser("update", help="Update issue")
    p.add_argument("key")
    p.add_argument("--summary")
    p.add_argument("--priority")
    p.add_argument("--assignee", "-a")
    p.add_argument("--add-labels")
    p.add_argument("--remove-labels")
    p.add_argument("--description", "-d")

    # move
    p = sub.add_parser("move", help="Transition issue status")
    p.add_argument("key")
    p.add_argument("status")

    # assign
    p = sub.add_parser("assign", help="Assign issue")
    p.add_argument("key")
    p.add_argument("user")

    # comment
    p = sub.add_parser("comment", help="Add comment")
    p.add_argument("key")
    p.add_argument("body")

    # link
    p = sub.add_parser("link", help="Link two issues")
    p.add_argument("from_key")
    p.add_argument("to_key")
    p.add_argument("--type", default="Relates")

    # label
    p = sub.add_parser("label", help="Add/remove labels")
    p.add_argument("key")
    p.add_argument("action", choices=["add", "remove"])
    p.add_argument("labels")

    # sprint
    p = sub.add_parser("sprint", help="Sprint board")
    p.add_argument("project", nargs="?")
    p.add_argument("--assignee", "-a")

    # fields
    p = sub.add_parser("fields", help="Issue types for project")
    p.add_argument("project", nargs="?")

    # users
    p = sub.add_parser("users", help="Search users")
    p.add_argument("query")

    # transitions
    p = sub.add_parser("transitions", help="Available transitions")
    p.add_argument("key")

    # attachments
    p = sub.add_parser("attachments", help="List attachments")
    p.add_argument("key")

    # projects
    sub.add_parser("projects", help="List all projects")

    # me
    sub.add_parser("me", help="Current user info")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    if not JIRA_URL or not JIRA_EMAIL or not JIRA_TOKEN:
        print("ERROR: Set JIRA_URL, JIRA_EMAIL, JIRA_TOKEN in .env file", file=sys.stderr)
        sys.exit(1)

    api = JiraAPI()

    commands = {
        "show": cmd_show, "search": cmd_search, "jql": cmd_jql,
        "mine": cmd_mine, "recent": cmd_recent, "children": cmd_children,
        "create": cmd_create, "update": cmd_update, "move": cmd_move,
        "assign": cmd_assign, "comment": cmd_comment, "link": cmd_link,
        "label": cmd_label, "sprint": cmd_sprint, "fields": cmd_fields,
        "users": cmd_users, "transitions": cmd_transitions,
        "attachments": cmd_attachments, "projects": cmd_projects, "me": cmd_me,
    }

    handler = commands.get(args.command)
    if handler:
        handler(api, args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
