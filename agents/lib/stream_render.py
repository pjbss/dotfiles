#!/usr/bin/env python3
"""stream_render.py

Renders one `claude -p --output-format stream-json` event stream into labeled,
colored, one-line-per-event terminal output for `bin/pj-run-issues`.

The loop used to invoke `claude -p` in its default text mode, which prints
nothing at all until the phase ends and then emits one undifferentiated blob.
An unattended run is exactly the case where that is least acceptable: the whole
reason to watch it is to see, while it happens, that the implementing agent is
working on the issue you meant and the reviewer is a separate process that
actually re-read the code. So the loop asks for the event stream instead, and
this turns it back into something a human can follow.

Every line carries the label of the agent that produced it (`tdd`, `rev`,
`fix`), so three phases scrolling past in one terminal stay distinguishable
after the fact, not just while you remember which one you started. Events with
a `parent_tool_use_id` came from a subagent the phase spawned -- pj-tdd's
pj-test-auditor, say -- and are indented under it rather than flattened in,
since "the implementer checked its own tests" and "a separate auditor checked
them" are different claims.

Two output streams, one process: colored lines to stdout for the terminal, the
same lines without escapes appended to --log. `tee` can't do that -- it would
copy whichever of the two forms it was handed -- and a log full of escape
sequences is a log nobody greps.

Robustness is a hard requirement rather than a nicety. This sits mid-pipeline in
an unattended loop that may run for hours: a malformed line, a schema that
shifted under a `claude` upgrade, or a reader that went away must never be what
takes the run down. Anything unparseable is passed through verbatim (that is
also where claude's own stderr lands, and swallowing it would hide real
failures), anything unrecognized is dropped, and every failure mode exits 0.

Usage: stream_render.py --label LABEL [--log PATH] [--color] [--width N]
"""

import argparse
import json
import os
import signal
import sys
import time

# A filter whose reader went away is not this program's failure to report, and
# a Python traceback on stderr would be the last thing an unattended run needs.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

# Mirrors sandbox/lib/color.sh, which owns this palette for the shell side.
# Duplicated rather than threaded through argv because this is a separate
# process and passing six escape strings as arguments would be worse than
# restating three-byte constants; keep the two in step.
LABEL_COLORS = {
    "tdd": "\033[32m",      # green
    "rev": "\033[35m",      # magenta
    "fix": "\033[33m",      # yellow
    "gate": "\033[34m",     # blue
    "loop": "\033[36m",     # cyan
}
DIM = "\033[2m"
RED = "\033[31m"
RESET = "\033[0m"

# Event types that carry no information a human watching a run wants: session
# bookkeeping, the hook chatter every session start emits, and a rate-limit
# heartbeat that arrives between every pair of real events.
DROPPED_SYSTEM_SUBTYPES = {
    "init",
    "hook_started",
    "hook_response",
    "commands_changed",
}


def _text(value):
    """Best-effort flattening of a content field that may be str or blocks."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for block in value:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return " ".join(parts)
    if value is None:
        return ""
    return str(value)


def _oneline(value, limit):
    """Collapse to a single line and truncate, so no summary can wrap."""
    collapsed = " ".join(_text(value).split())
    if limit and len(collapsed) > limit:
        return collapsed[: max(1, limit - 1)] + "…"
    return collapsed


def summarize_tool(name, tool_input, limit):
    """One short line describing what a tool call is about to do.

    Each tool gets the field that answers "on what?" -- a path for the file
    tools, the command for Bash, the subagent's name for a launch -- because
    the tool name alone ("Edit") says nothing about whether the agent is
    working where you expected it to.
    """
    if not isinstance(tool_input, dict):
        return ""

    if name == "Bash":
        return _oneline(tool_input.get("command") or tool_input.get("description"), limit)
    if name in ("Read", "Write", "Edit", "NotebookEdit"):
        return _oneline(_relative(tool_input.get("file_path", "")), limit)
    if name in ("Agent", "Task"):
        return _oneline(
            tool_input.get("subagent_type") or tool_input.get("description"), limit
        )
    if name == "Skill":
        return _oneline(tool_input.get("skill"), limit)
    if name == "Glob":
        return _oneline(tool_input.get("pattern"), limit)
    if name == "Grep":
        pattern = _oneline(tool_input.get("pattern"), limit)
        path = _relative(tool_input.get("path", ""))
        return "{} {}".format(pattern, path).strip() if path else pattern
    if name == "TodoWrite":
        todos = tool_input.get("todos")
        if isinstance(todos, list):
            for todo in todos:
                if isinstance(todo, dict) and todo.get("status") == "in_progress":
                    return _oneline(todo.get("activeForm") or todo.get("content"), limit)
        return ""
    if name in ("WebFetch", "WebSearch"):
        return _oneline(tool_input.get("url") or tool_input.get("query"), limit)

    # An unknown tool still gets a line -- the name alone is enough to notice
    # an agent reaching for something the issue never called for.
    return _oneline(tool_input.get("description", ""), limit)


def _relative(path):
    """Paths relative to the project, since the absolute prefix is the same
    on every line and pushes the part that differs off the right edge."""
    if not isinstance(path, str) or not path:
        return ""
    try:
        cwd = os.getcwd()
    except OSError:
        return path
    if path.startswith(cwd + os.sep):
        return path[len(cwd) + 1 :]
    return path


def _duration(event):
    ms = event.get("duration_ms")
    if not isinstance(ms, (int, float)):
        return ""
    seconds = int(ms / 1000)
    return "{}m{:02d}s".format(seconds // 60, seconds % 60)


def _cost(event):
    cost = event.get("total_cost_usd")
    if not isinstance(cost, (int, float)):
        return ""
    return "${:.2f}".format(cost)


class Renderer:
    def __init__(self, label, out, log, color, width):
        self.label = label
        self.out = out
        self.log = log
        self.color = color
        self.width = width
        # tool_use id -> tool name, so a failure can say what failed rather
        # than just that something did.
        self.tools = {}

    def emit(self, glyph, body, nested=False, style=None):
        stamp = _timestamp()
        indent = "  " if nested else ""
        marker = "↳" if nested else glyph
        prefix = "{} {:<4} {}{} ".format(stamp, self.label, indent, marker)

        # Truncate the assembled line rather than each field on the way in:
        # a field doesn't know what the prefix in front of it costs, and a line
        # that wraps has lost the column alignment that makes the stream
        # skimmable in the first place.
        if self.width:
            room = self.width - len(prefix)
            if room > 1 and len(body) > room:
                body = body[: room - 1] + "…"

        plain = prefix + body

        if self.log is not None:
            self.log.write(plain + "\n")
            self.log.flush()

        if self.color:
            label_color = LABEL_COLORS.get(self.label, LABEL_COLORS["loop"])
            body_open = style or ""
            body_close = RESET if style else ""
            line = "{}{}{} {}{}{} {}{} {}{}{}".format(
                DIM, stamp, RESET,
                label_color, "{:<4}".format(self.label), RESET,
                indent, marker,
                body_open, body, body_close,
            )
        else:
            line = plain

        self.out.write(line + "\n")
        self.out.flush()

    def passthrough(self, raw):
        """A line that isn't an event at all -- claude's own stderr, most
        likely. Shown rather than dropped: it is where a real failure says so."""
        if not raw.strip():
            return
        self.emit("!", _oneline(raw, self.width), style=DIM)

    def handle(self, event):
        kind = event.get("type")
        nested = bool(event.get("parent_tool_use_id"))

        if kind == "assistant":
            self._handle_assistant(event, nested)
        elif kind == "user":
            self._handle_user(event, nested)
        elif kind == "result":
            self._handle_result(event)
        # system/rate_limit_event and anything unrecognized: dropped on
        # purpose. A watcher wants the work, not the session bookkeeping.

    def _handle_assistant(self, event, nested):
        message = event.get("message")
        if not isinstance(message, dict):
            return
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                name = block.get("name", "?")
                self.tools[block.get("id")] = name
                budget = self.width or 0
                summary = summarize_tool(name, block.get("input"), budget)
                self.emit("▸", "{:<7}{}".format(name, summary).rstrip(), nested=nested)
            elif block.get("type") == "text":
                text = _oneline(block.get("text"), self.width or 0)
                if text:
                    self.emit("·", text, nested=nested, style=DIM)

    def _handle_user(self, event, nested):
        message = event.get("message")
        if not isinstance(message, dict):
            return
        for block in message.get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            # Only failures. A successful result is the tool's whole stdout,
            # which is both the bulkiest thing in the stream and the thing the
            # agent is already summarizing for you.
            if not block.get("is_error"):
                continue
            tool = self.tools.get(block.get("tool_use_id"), "")
            detail = _oneline(block.get("content"), self.width or 0)
            body = "{:<7}{}".format(tool, detail).rstrip() if tool else detail
            self.emit("✗", body, nested=nested, style=RED)

    def _handle_result(self, event):
        parts = [p for p in (_duration(event), _cost(event)) if p]
        if event.get("is_error") or event.get("subtype") not in (None, "success"):
            reason = _oneline(event.get("subtype") or "error", 40)
            self.emit("✗", " ".join(["failed", reason] + parts), style=RED)
        else:
            self.emit("✓", "  ".join(["finished"] + parts))


def _timestamp():
    return time.strftime("%H:%M:%S")


def main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--label", default="loop")
    parser.add_argument("--log")
    parser.add_argument("--color", action="store_true")
    parser.add_argument("--width", type=int, default=100)
    args = parser.parse_args(argv)

    log = None
    if args.log:
        try:
            log = open(args.log, "a", encoding="utf-8", errors="replace")
        except OSError:
            # A log we can't open is not a reason to lose the live output.
            log = None

    renderer = Renderer(args.label, sys.stdout, log, args.color, args.width)

    try:
        for raw in sys.stdin:
            raw = raw.rstrip("\n")
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except ValueError:
                renderer.passthrough(raw)
                continue
            if not isinstance(event, dict):
                renderer.passthrough(raw)
                continue
            try:
                renderer.handle(event)
            except Exception:
                # A schema this doesn't understand is a rendering problem, not
                # a reason to fail the run it is narrating.
                renderer.passthrough(raw)
    except BrokenPipeError:
        pass
    except KeyboardInterrupt:
        pass
    finally:
        if log is not None:
            try:
                log.close()
            except OSError:
                pass

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
