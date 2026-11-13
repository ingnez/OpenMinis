"""Structured reports, workspace usage, and device drafts on iOS and the VPS.

Workflow references: OpenMinis/MinisSkills at 6de9d86f3743116eccdd635ab6d8eb4b5254df2d
(generative-ui-minis, disk-scan, shortcuts-builder, and apple-reminders).
"""

import argparse
from datetime import datetime
import heapq
import html
import json
import math
import os
import plistlib
import re
from pathlib import Path
import stat
import tempfile
from urllib.parse import urlsplit
import uuid


REPORT_CSS = """
:root{color-scheme:light dark;font:16px system-ui,sans-serif}
body{margin:0;padding:24px;line-height:1.55}main{max-width:56rem;margin:auto}
h1,h2{line-height:1.2}section{margin-block:24px}table{border-collapse:collapse;width:100%}
th,td{border-bottom:1px solid #8886;padding:8px;text-align:start;overflow-wrap:anywhere}
.scroll{overflow:auto}meter{width:100%;accent-color:#4369cc}
small{display:block}pre{white-space:pre-wrap;overflow-wrap:anywhere}
"""

LOCAL_ROOTS = (Path("/var/minis/workspace"), Path("/var/minis/attachments"))
REPORT_LIMIT = 1_000_000


def _text(value, limit=4000):
    if value is None:
        return ""
    if not isinstance(value, (str, int, float, bool)):
        raise ValueError("Report cells and labels must be text or scalar values")
    if len(str(value)) > limit:
        raise ValueError(f"Report text exceeds {limit} characters")
    return html.escape(str(value))


def _items(obj, key, limit):
    items = obj.get(key, [])
    if not isinstance(items, list) or len(items) > limit:
        raise ValueError(f"{key} must be a list with at most {limit} items")
    return items


def _render_block(block):
    if not isinstance(block, dict):
        raise ValueError("Report blocks must be objects")
    kind = block.get("type")
    title = _text(block.get("title"), 200)
    heading = f"<h2>{title}</h2>" if title else ""
    if kind == "table":
        columns = _items(block, "columns", 12)
        if not columns:
            raise ValueError("A table needs at least one column")
        cells = []
        for row in _items(block, "rows", 200):
            if not isinstance(row, list) or len(row) != len(columns):
                raise ValueError("Table rows must match the number of columns")
            cells.append("<tr>" + "".join(f"<td>{_text(cell)}</td>" for cell in row) + "</tr>")
        header = "".join(f'<th scope="col">{_text(name)}</th>' for name in columns)
        content = f'<div class="scroll"><table><thead><tr>{header}</tr></thead><tbody>{"".join(cells)}</tbody></table></div>'
    elif kind in ("records", "timeline", "chart", "cards"):
        items = _items(block, "items", 100)
        if any(not isinstance(item, dict) for item in items):
            raise ValueError("Report items must be objects")
        if kind == "chart":
            values = [item.get("value") for item in items]
            if any(type(n) not in (int, float) or not -1e15 <= n <= 1e15 or not math.isfinite(n) for n in values):
                raise ValueError("Chart values must be finite numbers within ±1e15")
            lo, hi = min([0, *values]), max([0, *values])
            content = "".join(
                f'<p>{_text(item.get("label"))} <strong>{value}</strong><small>'
                f'<meter aria-label="{_text(item.get("label"))}" min="{lo}" max="{(hi if lo != hi else 1)}" value="{value}"></meter></small></p>'
                for item, value in zip(items, values)
            )
        else:
            tag = "ol" if kind == "timeline" else "ul"
            content = f"<{tag}>" + "".join(
                f'<li><strong>{_text(item.get("title"))}</strong> {_text(item.get("text"))}</li>' for item in items
            ) + f"</{tag}>"
    elif kind == "text":
        content = f'<pre>{_text(block.get("text"))}</pre>'
    else:
        raise ValueError(f"Unsupported report block: {kind}")
    return f"<section>{heading}{content}</section>"


def render_report(title, blocks, summary=""):
    if not isinstance(title, str) or not title.strip():
        raise ValueError("Report title is required")
    heading = _text(title.strip(), 200)
    if not isinstance(blocks, list) or not 1 <= len(blocks) <= 20:
        raise ValueError("A report needs 1–20 blocks")
    parts = [
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">',
        f"<title>{heading}</title><style>{REPORT_CSS}</style></head><body><main><h1>{heading}</h1>",
        f"<p>{_text(summary)}</p>" if summary else "",
    ]
    size = sum(len(part.encode()) for part in parts)
    for block in blocks:
        part = _render_block(block)
        size += len(part.encode())
        if size > REPORT_LIMIT:
            raise ValueError("Report exceeds 1 MB")
        parts.append(part)
    return "".join(parts) + "</main></body></html>"


def scan_workspace(root, relative_path=".", limit=15, max_entries=100_000):
    """Sum logical bytes without following links or opening file contents."""
    if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
        raise ValueError("A workspace-relative directory is required")
    relative = Path(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Directory must be within the current workspace")
    if type(limit) is not int or not 1 <= limit <= 50:
        raise ValueError("limit must be 1–50")
    root = Path(root).resolve(strict=True)
    base = root
    for part in relative.parts:
        base = base / part
        if base.is_symlink():
            raise ValueError("Directory must not contain a symbolic link")
    if not base.is_dir():
        raise ValueError("Directory does not exist in this workspace")

    total = count = skipped = visited = 0
    truncated = False
    directories = {}
    largest = []

    def inaccessible(_error):
        nonlocal skipped
        skipped += 1

    for directory, children, files in os.walk(base, topdown=True, onerror=inaccessible, followlinks=False):
        current = Path(directory).relative_to(base)
        for name in children + files:
            if visited >= max_entries:
                truncated = True
                break
            visited += 1
            path = Path(directory) / name
            try:
                info = path.lstat()
            except OSError:
                inaccessible(None)
                continue
            if stat.S_ISLNK(info.st_mode):
                skipped += 1
            if not stat.S_ISREG(info.st_mode):
                continue
            size = info.st_size
            total += size
            count += 1
            item = (size, str(current / name))
            if len(largest) < limit:
                heapq.heappush(largest, item)
            else:
                heapq.heappushpop(largest, item)
            for folder in (current, *current.parents):
                if folder == Path("."):
                    break
                directories[folder] = directories.get(folder, 0) + size
        if truncated:
            break

    def rows(pairs):
        return [{"path": str(path), "bytes": size} for size, path in pairs]

    return {
        "path": str(relative), "total_bytes": total, "file_count": count,
        "skipped_entries": skipped, "truncated": truncated,
        "largest_files": rows(sorted(largest, reverse=True)),
        "largest_dirs": rows(heapq.nlargest(limit, ((size, str(path)) for path, size in directories.items()))),
    }


def reminder_draft(args):
    title, notes, due = args.get("title"), args.get("notes", ""), args.get("due", "")
    if not isinstance(title, str) or not title.strip() or len(title.strip()) > 200:
        raise ValueError("Reminder title must contain 1–200 characters")
    if not isinstance(notes, str) or len(notes) > 4000:
        raise ValueError("Reminder notes must be text up to 4000 characters")
    if not isinstance(due, str):
        raise ValueError("Reminder date must be a string")
    if due:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?", due):
            raise ValueError("Use YYYY-MM-DD or YYYY-MM-DDTHH:MM")
        try:
            datetime.fromisoformat(due)
        except ValueError as error:
            raise ValueError("Reminder date is invalid") from error
    return {"title": title.strip(), "notes": notes.strip(), "due": due}


def shortcut_draft(args):
    """Build a fixed set of Apple Shortcuts actions from a small, typed input."""
    title = args.get("title")
    if not isinstance(title, str) or not title.strip() or len(title.strip()) > 120:
        raise ValueError("Shortcut title must contain 1–120 characters")
    text = args.get("text")
    url = args.get("url")
    if (text is None) == (url is None):
        raise ValueError("Supply either text or a URL")
    input_name, input_field, output_name = "gettext", "WFTextActionText", "Text"
    if url is not None:
        if not isinstance(url, str) or len(url) > 2048 or any(c.isspace() for c in url):
            raise ValueError("Enter an HTTP or HTTPS URL")
        parsed = urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username is not None:
            raise ValueError("Enter an HTTP or HTTPS URL without credentials")
        text = url
        input_name, input_field, output_name = "url", "WFURLActionURL", "URL"
        action = "openurl"
    else:
        action = args.get("action", "show")
        if action not in ("show", "share"):
            raise ValueError("Text shortcuts can display or share text")
        action = "showresult" if action == "show" else "share"
    if not isinstance(text, str) or not text.strip() or len(text) > 10_000:
        raise ValueError("Shortcut input must contain 1–10000 characters")
    output = str(uuid.uuid4()).upper()
    reference = {"OutputName": output_name, "OutputUUID": output, "Type": "ActionOutput"}
    if action == "showresult":
        parameters = {"Text": {"Value": {"attachmentsByRange": {"{0, 1}": reference}, "string": "\uFFFC"},
                               "WFSerializationType": "WFTextTokenString"}}
    else:
        parameters = {"WFInput": {"Value": reference, "WFSerializationType": "WFTextTokenAttachment"}}
    descriptions = {
        "showresult": "显示这段文字。",
        "share": "打开系统分享菜单，由用户选择分享目标。",
        "openurl": "打开草稿里显示的网页。",
    }
    actions = [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.comment",
         "WFWorkflowActionParameters": {"WFCommentActionText": descriptions[action]}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.comment",
         "WFWorkflowActionParameters": {"WFCommentActionText": (
             "Shortcuts generated by Shortcuts Playground. May contain mistakes. "
             "Always check the shortcut's actions first."
         )}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions." + input_name,
         "WFWorkflowActionParameters": {"UUID": output, input_field: text}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions." + action,
         "WFWorkflowActionParameters": parameters},
    ]
    try:
        return plistlib.dumps({
            "WFWorkflowName": title.strip(), "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2700.0.4", "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowTypes": [],
            "WFWorkflowImportQuestions": [], "WFWorkflowHasOutputFallback": False,
            "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 61440, "WFWorkflowIconStartColor": 431817727},
        })
    except ValueError as error:
        raise ValueError("Shortcut contains characters that cannot be stored in XML") from error


def _local_root(path):
    for root in LOCAL_ROOTS:
        if path.is_relative_to(root):
            return root
    raise ValueError("Use a path within /var/minis/workspace or /var/minis/attachments")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("report", "shortcut"):
        output_command = commands.add_parser(name)
        output_command.add_argument("spec", type=Path, help="JSON input in the workspace")
        output_command.add_argument("output", type=Path, help="Output file in the workspace")
    disk = commands.add_parser("scan")
    disk.add_argument("directory", type=Path)
    disk.add_argument("--limit", type=int, default=15)
    args = parser.parse_args()
    try:
        if args.command == "scan":
            root = _local_root(args.directory)
            result = scan_workspace(root, str(args.directory.relative_to(root)), args.limit)
        else:
            spec_path = args.spec.resolve(strict=True)
            output = args.output.resolve()
            _local_root(spec_path)
            _local_root(output)
            extension = ".html" if args.command == "report" else ".xml"
            if output.suffix.lower() != extension:
                raise ValueError(f"Output must have an {extension} extension")
            if spec_path.stat().st_size > REPORT_LIMIT:
                raise ValueError("Input exceeds 1 MB")
            spec = json.loads(spec_path.read_text(encoding="utf-8"))
            if not isinstance(spec, dict):
                raise ValueError("Input must be a JSON object")
            if args.command == "report":
                document = render_report(spec.get("title"), spec.get("blocks"), spec.get("summary")).encode()
            else:
                document = shortcut_draft(spec)
            with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as tmp:
                tmp_path = Path(tmp.name)
                try:
                    tmp.write(document)
                    tmp.close()
                    os.replace(tmp_path, output)
                finally:
                    tmp_path.unlink(missing_ok=True)
            result = {"path": str(output)}
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
