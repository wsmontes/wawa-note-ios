#!/usr/bin/env python3
"""
confluence-sync.py — Push docs/ markdown files to Confluence wiki.
Shares credentials with jira-cli.py via the same .env file.

Usage:
    python confluence-sync.py list-spaces
    python confluence-sync.py list-pages --space WAWA
    python confluence-sync.py push <file.md> --space WAWA --parent "Technical Docs"
    python confluence-sync.py push-all --space WAWA --parent "Wawa Note Docs"
    python confluence-sync.py push-dir docs/ --space WAWA --dry-run
"""

import os
import sys
import json
import argparse
from pathlib import Path
import requests
from requests.auth import HTTPBasicAuth


def load_env():
    for p in [Path(__file__).parent / '.env', Path.cwd() / '.env']:
        if p.exists():
            for line in p.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    os.environ.setdefault(k.strip(), v.strip())
            return
    print("ERROR: No .env file found", file=sys.stderr)
    sys.exit(1)


load_env()

JIRA_URL = os.environ.get('JIRA_URL', '').rstrip('/')
EMAIL = os.environ.get('JIRA_EMAIL', '')
TOKEN = os.environ.get('JIRA_TOKEN', '')

# Confluence uses the same base URL
CONFLUENCE_URL = JIRA_URL  # wawasoftbc.atlassian.net


class ConfluenceAPI:
    def __init__(self):
        self.base = f"{CONFLUENCE_URL}/wiki/api/v2"
        self.session = requests.Session()
        self.session.auth = HTTPBasicAuth(EMAIL, TOKEN)
        self.session.verify = True
        self.session.headers.update({
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        })

    def get(self, path, params=None):
        r = self.session.get(f"{self.base}{path}", params=params, timeout=30)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()

    def post(self, path, data):
        r = self.session.post(f"{self.base}{path}", json=data, timeout=30)
        r.raise_for_status()
        return r.json()

    def put(self, path, data):
        r = self.session.put(f"{self.base}{path}", json=data, timeout=30)
        r.raise_for_status()
        return r.json()

    def list_spaces(self):
        """List all Confluence spaces."""
        result = self.get("/spaces")
        if result:
            for s in result.get("results", []):
                print(f"  {s['key']:10} — {s['name']}  ({s.get('type', '')})")
        else:
            print("No spaces found or no access.")

    def get_space(self, space_key):
        """Get space details by key. Returns dict with id, key, name."""
        # Try direct lookup first (numeric ID or short key)
        result = self.get(f"/spaces/{space_key}")
        if result:
            return result
        # Try by keys parameter (for personal space keys with ~)
        r = self.session.get(f"{self.base}/spaces", params={"keys": space_key}, timeout=30)
        if r.status_code == 200:
            results = r.json().get("results", [])
            if results:
                return results[0]
        return None

    def resolve_space_id(self, space_ref):
        """Resolve a space key or name to a numeric space ID."""
        # If already numeric, return as-is
        if space_ref.isdigit():
            return space_ref, None
        # Try by keys parameter
        r = self.session.get(f"{self.base}/spaces", params={"keys": space_ref}, timeout=30)
        if r.status_code == 200:
            results = r.json().get("results", [])
            if results:
                return results[0]["id"], results[0]
        # Try by name
        r = self.session.get(f"{self.base}/spaces", params={"query": space_ref}, timeout=30)
        if r.status_code == 200:
            results = r.json().get("results", [])
            if results:
                return results[0]["id"], results[0]
        return None, None

    def list_pages(self, space_key, parent_id=None):
        """List pages in a space, optionally under a parent."""
        params = {"space-id": space_key, "limit": 50}
        result = self.get("/pages", params=params)
        if result:
            for p in result.get("results", []):
                print(f"  {p['id']:12} — {p['title']:50}  ({p.get('status', '')})")

    def get_page_by_title(self, space_ref, title):
        """Find a page by title in a space. Resolves key to numeric ID."""
        space_id, _ = self.resolve_space_id(space_ref)
        if not space_id:
            return None
        params = {"space-id": space_id, "title": title, "limit": 1}
        result = self.get("/pages", params=params)
        if result and result.get("results"):
            return result["results"][0]
        return None

    def create_page(self, space_id, title, body_markdown, parent_id=None):
        """Create a new page with markdown body."""
        data = {
            "spaceId": space_id,
            "status": "current",
            "title": title,
            "body": {
                "representation": "storage",
                "value": self._markdown_to_storage(body_markdown)
            }
        }
        if parent_id:
            data["parentId"] = parent_id
        return self.post("/pages", data)

    def update_page(self, page_id, title, body_markdown, version):
        """Update an existing page."""
        data = {
            "id": page_id,
            "status": "current",
            "title": title,
            "body": {
                "representation": "storage",
                "value": self._markdown_to_storage(body_markdown)
            },
            "version": {
                "number": version + 1,
                "message": "Updated via confluence-sync.py"
            }
        }
        return self.put(f"/pages/{page_id}", data)

    def _markdown_to_storage(self, md_text):
        """Convert markdown to Confluence Storage Format (basic)."""
        # Escape HTML entities
        import re
        text = md_text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

        # Headers
        text = re.sub(r'^#### (.+)$', r'<h4>\1</h4>', text, flags=re.MULTILINE)
        text = re.sub(r'^### (.+)$', r'<h3>\1</h3>', text, flags=re.MULTILINE)
        text = re.sub(r'^## (.+)$', r'<h2>\1</h2>', text, flags=re.MULTILINE)
        text = re.sub(r'^# (.+)$', r'<h1>\1</h1>', text, flags=re.MULTILINE)

        # Bold
        text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)

        # Code
        text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)

        # Code blocks
        text = re.sub(r'```(\w*)\n(.*?)```', r'<ac:structured-macro ac:name="code"><ac:parameter ac:name="language">\1</ac:parameter><ac:plain-text-body><![CDATA[\2]]></ac:plain-text-body></ac:structured-macro>', text, flags=re.DOTALL)

        # Links
        text = re.sub(r'\[([^\]]+)\]\(([^\)]+)\)', r'<a href="\2">\1</a>', text)

        # Tables
        lines = text.split('\n')
        in_table = False
        result = []
        for line in lines:
            if line.startswith('|') and line.endswith('|') and '---' not in line:
                cells = [c.strip() for c in line.split('|')[1:-1]]
                if not in_table:
                    result.append('<table>')
                    in_table = True
                is_header = all(c.startswith('**') and c.endswith('**') for c in cells if c)
                tag = 'th' if is_header else 'td'
                clean = [c.replace('**', '') for c in cells]
                result.append('<tr>' + ''.join(f'<{tag}>{c}</{tag}>' for c in clean) + '</tr>')
            else:
                if in_table:
                    result.append('</table>')
                    in_table = False
                result.append(line)
        if in_table:
            result.append('</table>')
        text = '\n'.join(result)

        # Paragraphs
        paragraphs = text.split('\n\n')
        wrapped = []
        for p in paragraphs:
            p = p.strip()
            if not p or p.startswith('<'):
                wrapped.append(p)
            else:
                wrapped.append(f'<p>{p}</p>')
        text = '\n'.join(wrapped)

        return text


def cmd_list_spaces(api, args):
    print("Confluence Spaces:")
    api.list_spaces()


def cmd_list_pages(api, args):
    space_id, space = api.resolve_space_id(args.space)
    if not space_id:
        print(f"ERROR: Space '{args.space}' not found", file=sys.stderr)
        sys.exit(1)
    print(f"Pages in {space['name']} (ID: {space_id}):")
    params = {"space-id": space_id, "limit": 50, "sort": "-modified-date"}
    result = api.get("/pages", params=params)
    if result:
        for p in result.get("results", []):
            print(f"  {p['id']:12} — {p['title']:50}  ({p.get('status', '')})")


def cmd_push(api, args):
    filepath = Path(args.file)
    if not filepath.exists():
        print(f"ERROR: File not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    md_content = filepath.read_text()
    title = args.title or filepath.stem.replace('-', ' ').replace('_', ' ').title()

    space_id, space = api.resolve_space_id(args.space)
    if not space_id:
        print(f"ERROR: Space '{args.space}' not found", file=sys.stderr)
        sys.exit(1)

    space_name = space["name"]

    existing = api.get_page_by_title(args.space, title)
    if existing:
        print(f"Updating existing page: {existing['id']} — {title}")
        version = existing.get("version", {}).get("number", 0)
        api.update_page(existing["id"], title, md_content, version)
        print(f"  Updated to version {version + 1}")
    else:
        print(f"Creating new page: {title} in {args.space}")
        result = api.create_page(space_id, title, md_content, parent_id=args.parent)
        print(f"  Created: {result['id']}")


def cmd_push_all(api, args):
    """Push all markdown files from docs/ to Confluence."""
    docs_dir = Path(args.dir) if args.dir else Path("docs")
    if not docs_dir.exists():
        print(f"ERROR: Directory not found: {args.dir}", file=sys.stderr)
        sys.exit(1)

    space_id, space = api.resolve_space_id(args.space)
    if not space_id:
        print(f"ERROR: Space '{args.space}' not found", file=sys.stderr)
        sys.exit(1)

    md_files = sorted(docs_dir.glob("*.md"))
    print(f"Found {len(md_files)} markdown files in {docs_dir}/")
    if args.dry_run:
        print("DRY RUN — no changes will be made:")
        for f in md_files:
            print(f"  Would push: {f.name}")
        return

    for f in md_files:
        if f.name.startswith('TODO_') or f.name.startswith('MASTER_'):
            print(f"  SKIP (todo list): {f.name}")
            continue
        title = f.stem.replace('-', ' ').replace('_', ' ').title()
        md_content = f.read_text()

        existing = api.get_page_by_title(args.space, title)
        if existing:
            print(f"  UPDATE: {title}")
            version = existing.get("version", {}).get("number", 0)
            api.update_page(existing["id"], title, md_content, version)
        else:
            print(f"  CREATE: {title}")
            api.create_page(space_id, title, md_content, parent_id=args.parent)

    print(f"\nPushed {len(md_files)} files to {args.space}")


def main():
    parser = argparse.ArgumentParser(description="Confluence documentation sync")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("list-spaces", help="List Confluence spaces")
    p = sub.add_parser("list-pages", help="List pages in a space")
    p.add_argument("--space", "-s", required=True)

    p = sub.add_parser("push", help="Push a single file")
    p.add_argument("file")
    p.add_argument("--space", "-s", required=True)
    p.add_argument("--title", "-t")
    p.add_argument("--parent")

    p = sub.add_parser("push-all", help="Push all docs/ files")
    p.add_argument("--space", "-s", required=True)
    p.add_argument("--dir", "-d", default="docs")
    p.add_argument("--parent")
    p.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()
    api = ConfluenceAPI()

    if args.command == "list-spaces":
        cmd_list_spaces(api, args)
    elif args.command == "list-pages":
        cmd_list_pages(api, args)
    elif args.command == "push":
        cmd_push(api, args)
    elif args.command == "push-all":
        cmd_push_all(api, args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
