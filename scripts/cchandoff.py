#!/usr/bin/env python3
"""Create a portable Claude Code session handoff bundle.

The bundle intentionally excludes thinking/signature blocks from the bootstrap
prompt path. They remain in the original transcript for audit, but cross-provider
resume must not replay them because signatures can be provider-sensitive.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip())
    slug = slug.strip("-._")
    return slug[:80] or "session"


def encoded_project_dir(project: Path, claude_dir: Path) -> Path:
    encoded = "-" + str(project.resolve()).strip("/").replace("/", "-")
    return claude_dir / "projects" / encoded


def transcript_path(project: Path, session_id: str, claude_dir: Path) -> Path:
    path = encoded_project_dir(project, claude_dir) / f"{session_id}.jsonl"
    if path.exists():
        return path
    matches = list((claude_dir / "projects").glob(f"*/{session_id}.jsonl"))
    if matches:
        return matches[0]
    raise FileNotFoundError(f"transcript not found for session {session_id}")


def read_jsonl(path: Path) -> list[tuple[int, dict[str, Any]]]:
    rows: list[tuple[int, dict[str, Any]]] = []
    with path.open(encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                rows.append((lineno, json.loads(line)))
            except json.JSONDecodeError:
                rows.append((lineno, {"type": "parse_error", "raw": line[:1000]}))
    return rows


def content_text(content: Any, *, include_tool_json: bool = False) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            parts.append(str(block.get("text", "")))
        elif btype == "tool_use":
            name = block.get("name", "")
            tool_input = block.get("input")
            if include_tool_json:
                parts.append(
                    f"[tool_use {name}]\n"
                    + json.dumps(tool_input, ensure_ascii=False, indent=2, default=str)
                )
            else:
                parts.append(f"[tool_use {name}]")
        elif btype == "tool_result":
            value = block.get("content", "")
            if isinstance(value, str):
                parts.append(value)
            else:
                parts.append(json.dumps(value, ensure_ascii=False, indent=2, default=str))
        elif btype == "thinking":
            parts.append("[thinking block omitted: not portable across providers]")
    return "\n\n".join(p for p in parts if p)


def truncate(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + f"\n\n[truncated {len(value) - limit} chars]"


def run_git(project: Path, args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=project,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )
    except Exception as exc:
        return f"[git {' '.join(args)} failed: {exc}]"
    if result.returncode != 0:
        return result.stderr.strip() or f"[git {' '.join(args)} exited {result.returncode}]"
    return result.stdout


def memory_files(project: Path, claude_dir: Path) -> list[Path]:
    instruction_names = {"CLAUDE.md", "AGENTS.md"}
    candidates = [
        encoded_project_dir(project, claude_dir) / "memory",
        project / ".claude" / "memory",
    ]
    files: list[Path] = []
    for base in candidates:
        if base.is_dir():
            files.extend(sorted(p for p in base.rglob("*") if p.is_file()))

    instruction_files: list[Path] = []
    for parent in [project, *project.parents]:
        for name in instruction_names:
            path = parent / name
            if path.is_file():
                instruction_files.append(path)
        if parent == Path.home() or parent.parent == parent:
            break

    user_memory = claude_dir / "CLAUDE.md"
    if user_memory.is_file():
        instruction_files.append(user_memory)

    seen: set[Path] = set()
    ordered: list[Path] = []
    for file in [*instruction_files, *files]:
        resolved = file.resolve()
        if resolved not in seen:
            seen.add(resolved)
            ordered.append(file)
    return ordered


def strip_nonportable(value: Any) -> Any:
    if isinstance(value, dict):
        cleaned: dict[str, Any] = {}
        for key, item in value.items():
            if key in {"thinking", "signature"}:
                continue
            if key == "content" and isinstance(item, list):
                blocks = []
                omitted = 0
                for block in item:
                    if isinstance(block, dict) and block.get("type") == "thinking":
                        omitted += 1
                        continue
                    blocks.append(strip_nonportable(block))
                cleaned[key] = blocks
                if omitted:
                    cleaned["portableOmitted"] = cleaned.get("portableOmitted", []) + [
                        f"{omitted} thinking block(s)"
                    ]
                continue
            cleaned[key] = strip_nonportable(item)
        return cleaned
    if isinstance(value, list):
        return [strip_nonportable(item) for item in value]
    return value


def format_portable_transcript(rows: list[tuple[int, dict[str, Any]]]) -> str:
    out: list[str] = []
    for lineno, obj in rows:
        cleaned = strip_nonportable(copy.deepcopy(obj))
        if isinstance(cleaned, dict):
            cleaned["originalLine"] = lineno
        out.append(json.dumps(cleaned, ensure_ascii=False, default=str))
    return "\n".join(out) + "\n"


# 与 scripts/claude-rename、Swift SecretRedactor 同一套模式。handoff 是原会话的明文副本，
# 会话里但凡回显过 key 就会被原样抄进来（2026-09-27 实测 4 个包里散着 8 把上游 key，权限 644）。
SECRET_PATTERNS = [
    (re.compile(r"(?<![A-Za-z0-9])((?:yes)?sk-[A-Za-z0-9_\-.]{6})[A-Za-z0-9_\-.]{4,}"), r"\1***REDACTED***"),
    (re.compile(r"(ark-[a-f0-9\-]{6})[a-f0-9\-]{4,}"), r"\1***REDACTED***"),
    (re.compile(r"\b(c?cr[_\-][A-Za-z0-9_\-]{6})(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{8,}"), r"\1***REDACTED***"),
    (re.compile(r"\b([0-9a-f]{6})[0-9a-f]{26}\.[A-Za-z0-9]{16}\b"), r"\1***REDACTED***"),
    (re.compile(r"(Bearer\s+)[A-Za-z0-9_\-.]{12,}"), r"\1***REDACTED***"),
]


def redact(text: str) -> str:
    for pattern, repl in SECRET_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def write(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # 先建 600 空文件再写，避免按 umask 落成 644 的窗口期
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(redact(text))
    os.chmod(path, 0o600)


def build_indexes(rows: list[tuple[int, dict[str, Any]]]) -> dict[str, list[int]]:
    indexes = {
        "userMessages": [],
        "assistantTextMessages": [],
        "assistantToolUses": [],
        "toolResults": [],
        "thinkingBlocks": [],
        "apiErrors": [],
        "fileSnapshots": [],
        "lastPrompts": [],
        "permissionModes": [],
    }
    for lineno, obj in rows:
        typ = obj.get("type")
        subtype = obj.get("subtype")
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        role = msg.get("role")
        content = msg.get("content")
        if typ == "system" and subtype == "api_error":
            indexes["apiErrors"].append(lineno)
        if typ == "file-history-snapshot":
            indexes["fileSnapshots"].append(lineno)
        if typ == "last-prompt":
            indexes["lastPrompts"].append(lineno)
        if typ == "permission-mode":
            indexes["permissionModes"].append(lineno)
        if role == "user":
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content
            ):
                indexes["toolResults"].append(lineno)
            else:
                indexes["userMessages"].append(lineno)
        elif role == "assistant":
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "thinking" for b in content
            ):
                indexes["thinkingBlocks"].append(lineno)
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_use" for b in content
            ):
                indexes["assistantToolUses"].append(lineno)
            elif content_text(content):
                indexes["assistantTextMessages"].append(lineno)
    return indexes


def format_visible_messages(rows: list[tuple[int, dict[str, Any]]]) -> str:
    out = ["# Visible Messages", ""]
    for lineno, obj in rows:
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        role = msg.get("role")
        if role not in {"user", "assistant"}:
            continue
        text = content_text(msg.get("content"), include_tool_json=False)
        if not text:
            continue
        if "[thinking block omitted" in text and not text.replace(
            "[thinking block omitted: not portable across providers]", ""
        ).strip():
            continue
        ts = obj.get("timestamp", "")
        model = msg.get("model", "")
        out.append(f"## L{lineno} {ts} {role} {model}".rstrip())
        out.append("")
        out.append(text)
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def format_tool_results(rows: list[tuple[int, dict[str, Any]]]) -> str:
    out = ["# Tool Uses And Results", ""]
    for lineno, obj in rows:
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        blocks = [
            b
            for b in content
            if isinstance(b, dict) and b.get("type") in {"tool_use", "tool_result"}
        ]
        if not blocks:
            continue
        out.append(f"## L{lineno} {obj.get('timestamp', '')} {msg.get('role', '')}")
        out.append("")
        out.append(content_text(blocks, include_tool_json=True))
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def format_errors(rows: list[tuple[int, dict[str, Any]]]) -> str:
    out = ["# API Errors", ""]
    for lineno, obj in rows:
        if obj.get("type") == "system" and obj.get("subtype") == "api_error":
            out.append(f"## L{lineno} {obj.get('timestamp', '')}")
            out.append("")
            out.append(json.dumps(obj.get("error"), ensure_ascii=False, indent=2, default=str))
            out.append("")
        elif obj.get("isApiErrorMessage"):
            out.append(f"## L{lineno} {obj.get('timestamp', '')}")
            out.append("")
            out.append(content_text((obj.get("message") or {}).get("content")))
            out.append("")
    return "\n".join(out).rstrip() + "\n"


def format_memory(project: Path, claude_dir: Path) -> str:
    out = ["# Memory Index", ""]
    files = memory_files(project, claude_dir)
    if not files:
        out.append("(no memory files found)")
        return "\n".join(out) + "\n"
    for file in files:
        out.append(f"## {file}")
        out.append("")
        try:
            out.append(file.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:
            out.append(f"[read failed: {exc}]")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def first_user_goal(rows: list[tuple[int, dict[str, Any]]]) -> str:
    for _, obj in rows:
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        if msg.get("role") == "user":
            text = content_text(msg.get("content"))
            if text:
                return truncate(text.strip(), 800)
    return ""


def recent_user_messages(rows: list[tuple[int, dict[str, Any]]], limit: int = 8) -> list[str]:
    found: list[str] = []
    for lineno, obj in rows:
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        if msg.get("role") != "user":
            continue
        text = content_text(msg.get("content"))
        if text:
            found.append(f"L{lineno}: {truncate(text.strip(), 1000)}")
    return found[-limit:]


def format_handoff_md(
    *,
    args: argparse.Namespace,
    handoff_dir: Path,
    transcript: Path,
    rows: list[tuple[int, dict[str, Any]]],
    indexes: dict[str, list[int]],
) -> str:
    recent = "\n".join(f"- {item}" for item in recent_user_messages(rows))
    return f"""# Claude Code Provider Handoff

Created: {utc_now()}

## Purpose

This bundle transfers visible, portable context from one Claude Code provider to
another without replaying provider-sensitive thinking signatures.

## Source

- Source provider: `{args.source_provider}`
- Target provider: `{args.target_provider}`
- Source session: `{args.session_id}`
- Project: `{args.project}`
- Original transcript: `{transcript}`

## Non-Portable Data

Claude `thinking` blocks and `signature` fields are intentionally not used for
cross-provider resume. They are indexed for audit only. Do not paste them into
new API requests.

## First User Goal

{first_user_goal(rows) or "(not found)"}

## Recent User Messages

{recent or "(none)"}

## Required Reading Order

1. `{handoff_dir / "manifest.json"}`
2. `{handoff_dir / "visible-messages.md"}`
3. `{handoff_dir / "portable-transcript.jsonl"}`
4. `{handoff_dir / "tool-results.md"}`
5. `{handoff_dir / "git-state.patch"}`
6. `{handoff_dir / "memory-index.md"}`
7. Query the original transcript by line number only when audit details are unclear.

## Transcript Index Counts

- User messages: {len(indexes["userMessages"])}
- Assistant text messages: {len(indexes["assistantTextMessages"])}
- Tool uses: {len(indexes["assistantToolUses"])}
- Tool results: {len(indexes["toolResults"])}
- API errors: {len(indexes["apiErrors"])}
- File snapshots: {len(indexes["fileSnapshots"])}
- Thinking blocks omitted from portable context: {len(indexes["thinkingBlocks"])}
"""


def format_bootstrap_prompt(handoff_dir: Path) -> str:
    return f"""你正在接手一个 Claude Code 旧会话，原因是用户切换了 provider。

必须先读取 handoff 包：

1. {handoff_dir / "manifest.json"}
2. {handoff_dir / "handoff.md"}
3. {handoff_dir / "visible-messages.md"}
4. {handoff_dir / "portable-transcript.jsonl"}
5. {handoff_dir / "tool-results.md"}
6. {handoff_dir / "git-state.patch"}
7. {handoff_dir / "memory-index.md"}

要求：
- 这是跨 provider 接力，不要使用旧的 --resume。
- 不要依赖 hidden thinking，不要尝试读取或复用 signature。
- `portable-transcript.jsonl` 是去掉 thinking/signature 后的完整可移植会话记录，优先读它。
- 如果仍然不够，才读取 manifest 里的 originalTranscript 并按行号查证；不要复制其中的 thinking/signature。
- 先用中文简短说明你已接手并列出下一步，然后继续处理用户未完成的任务。
"""


def create_handoff(args: argparse.Namespace) -> Path:
    claude_dir = Path(os.environ.get("CCPOD_CLAUDE_DIR", Path.home() / ".claude")).expanduser()
    project = Path(args.project).expanduser().resolve()
    transcript = transcript_path(project, args.session_id, claude_dir)
    rows = read_jsonl(transcript)
    indexes = build_indexes(rows)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    name = f"{stamp}-{safe_slug(args.session_id)}-to-{safe_slug(args.target_provider)}"
    handoff_dir = claude_dir / "handoffs" / name
    handoff_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(handoff_dir.parent, 0o700)
    os.chmod(handoff_dir, 0o700)

    manifest = {
        "createdAt": utc_now(),
        "sourceSessionId": args.session_id,
        "sourceProvider": args.source_provider,
        "targetProvider": args.target_provider,
        "project": str(project),
        "originalTranscript": str(transcript),
        "handoffDir": str(handoff_dir),
        "mode": "cross-provider-handoff",
        "portableContextFiles": [
            "handoff.md",
            "visible-messages.md",
            "portable-transcript.jsonl",
            "tool-results.md",
            "api-errors.md",
            "git-state.patch",
            "memory-index.md",
            "transcript.index.json",
            "bootstrap-prompt.md",
        ],
        "excludedFromPortableContext": ["thinking", "signature"],
        "reason": "thinking signatures are provider-sensitive and not portable",
        "indexCounts": {key: len(value) for key, value in indexes.items()},
    }

    write(handoff_dir / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    write(handoff_dir / "transcript.index.json", json.dumps(indexes, ensure_ascii=False, indent=2) + "\n")
    write(handoff_dir / "visible-messages.md", format_visible_messages(rows))
    write(handoff_dir / "portable-transcript.jsonl", format_portable_transcript(rows))
    write(handoff_dir / "tool-results.md", format_tool_results(rows))
    write(handoff_dir / "api-errors.md", format_errors(rows))
    write(handoff_dir / "memory-index.md", format_memory(project, claude_dir))

    git_state = "\n".join(
        [
            "# Git State",
            "",
            "## branch",
            run_git(project, ["branch", "--show-current"]),
            "## status --short",
            run_git(project, ["status", "--short"]),
            "## diff",
            run_git(project, ["diff", "--", "."]),
            "## diff --cached",
            run_git(project, ["diff", "--cached", "--", "."]),
        ]
    )
    write(handoff_dir / "git-state.patch", git_state.rstrip() + "\n")
    write(
        handoff_dir / "handoff.md",
        format_handoff_md(
            args=args,
            handoff_dir=handoff_dir,
            transcript=transcript,
            rows=rows,
            indexes=indexes,
        ),
    )
    write(handoff_dir / "bootstrap-prompt.md", format_bootstrap_prompt(handoff_dir))
    return handoff_dir


def main() -> int:
    parser = argparse.ArgumentParser(description="Create portable Claude Code handoff bundle")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--source-provider", required=True)
    parser.add_argument("--target-provider", required=True)
    args = parser.parse_args()
    try:
        handoff = create_handoff(args)
    except Exception as exc:
        print(f"cchandoff failed: {exc}", file=sys.stderr)
        return 1
    print(handoff)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
