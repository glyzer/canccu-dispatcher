# SPDX-License-Identifier: AGPL-3.0-or-later
"""Consume a `claude -p --output-format stream-json` stream for the run engine (libexec/canccu-worker).

Usage: python3 canccu-stream.py <log file> <summary file> <turn budget> [usage file]  < stream
Appends readable lines to the log ([tN] assistant text and tool calls, │ tool results),
counts top-level turns, and writes a flat JSON summary at the end (turns, last_text,
have_result, bg_pending: the background commands and subagents it started that no later event
mentions as done, and from the result event: subtype, is_error, num_turns, cost, message, denials, and
its usage: tokens_in, tokens_out, cache_read, cache_write).
With a usage file, each rate_limit_event (the account's 5-hour and weekly usage shares) is
written there, atomically, with the time it was seen: canccu-dispatch's usage throttle reads it.
Exits 3 as soon as turn budget+1 starts (worker then kills claude), 0 at end of stream.
"""
import json
import os
import re
import sys
import time

log_path, summary_path, budget = sys.argv[1], sys.argv[2], int(sys.argv[3])
usage_path = sys.argv[4] if len(sys.argv) > 4 else ""
turns, last_id, last_text, result, code = 0, None, "", None, 0
# a headless run ends with its turn: work it left in the background is lost, and the run must not
# pass for done (#26). launched: tool_use_id → None until its result names the task's ids;
# pending: task id → its tool_use_id, cleared by a later user or system event that names it
# (and does not say it still runs: a poll of its output).
launched, pending = {}, {}
RUNNING = re.compile(r"\bstatus\W{0,4}running\b|still running", re.I)
TASK_ID = re.compile(r"\b(?:ID|Id|id|agentId|task_id|shell_id|bash_id)[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9_-]{4,})")


def tool_line(block):
    inp = block.get("input") or {}
    for k in ("command", "file_path", "pattern", "url", "description"):
        if inp.get(k):
            return f"→ {block.get('name')} {str(inp[k]).splitlines()[0][:200]}"
    return f"→ {block.get('name')}"


def result_text(block):
    content = block.get("content")
    if isinstance(content, list):
        content = "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return (content or "")[:1500]


with open(log_path, "a", encoding="utf-8") as log:
    def write(prefix, text):
        for line in text.splitlines():
            log.write(f"{prefix}{line}\n")
        log.flush()

    for raw in sys.stdin:
        try:
            ev = json.loads(raw)
        except ValueError:
            write("", raw.rstrip("\n"))
            continue
        kind = ev.get("type")
        if kind == "assistant" and ev.get("parent_tool_use_id") is None:
            msg = ev.get("message") or {}
            if msg.get("id") != last_id:
                last_id, turns = msg.get("id"), turns + 1
                if turns > budget:
                    write("", f"[t{turns}] turn budget of {budget} reached, stopping")
                    code = 3
                    break
            for b in msg.get("content", []):
                if b.get("type") == "tool_use" and (b.get("input") or {}).get("run_in_background") is True:
                    launched[b.get("id")] = None
            texts = [b.get("text", "") for b in msg.get("content", []) if b.get("type") == "text"]
            tools = [tool_line(b) for b in msg.get("content", []) if b.get("type") == "tool_use"]
            write(f"[t{turns}] ", "\n".join(texts + tools))
            if any(t.strip() for t in texts):
                last_text = "\n".join(texts)
        elif kind == "user" and ev.get("parent_tool_use_id") is None:
            for t in [t for t in pending if t in raw and not RUNNING.search(raw)]:
                del pending[t]
            for block in (ev.get("message") or {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    write("        │ ", result_text(block))
                    use = block.get("tool_use_id")
                    if use in launched and launched[use] is None:
                        ids = set(TASK_ID.findall(result_text(block))) or {use}
                        launched[use] = ids
                        if not block.get("is_error"):
                            pending.update((t, use) for t in ids)
        elif kind == "system":
            for t in [t for t in pending if t in raw and not RUNNING.search(raw)]:
                del pending[t]
        elif kind == "result":
            result = ev
        elif kind == "rate_limit_event" and usage_path:
            try:
                tmp = f"{usage_path}.tmp.{os.getpid()}"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump({"at": int(time.time()), "info": ev.get("rate_limit_info") or {}}, f)
                os.replace(tmp, usage_path)
            except OSError:
                pass

summary = {"turns": turns, "last_text": last_text, "have_result": result is not None,
           "bg_pending": len(set(pending.values()))}
if result is not None:
    denials = []
    for d in result.get("permission_denials") or []:
        inp = d.get("tool_input") or {}
        denials.append(f"{d.get('tool_name')} {inp.get('command') or inp.get('file_path') or ''}".strip())
    summary.update(
        subtype=result.get("subtype") or "",
        is_error=bool(result.get("is_error")),
        num_turns=result.get("num_turns") or turns,
        cost=f"{result.get('total_cost_usd') or 0:.2f}",
        message=result.get("result") or "\n".join(result.get("errors") or []),
        denials="\n".join(denials),
    )
    usage = result.get("usage") or {}
    for out, key in (("tokens_in", "input_tokens"), ("tokens_out", "output_tokens"),
                     ("cache_read", "cache_read_input_tokens"), ("cache_write", "cache_creation_input_tokens")):
        if isinstance(usage.get(key), int):
            summary[out] = usage[key]
with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(summary, f)
sys.exit(code)
