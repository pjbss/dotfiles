"""Reads a task's egress.log, the JSON lines policy.py and inject.py write.

Standard library only, like policy.py. lib/cmd_logs.sh runs it as:

    python3 egress_log.py show LOG [--denied] [--follow] [--json]

which prints a table (or, with --json, the matching lines unchanged), and
--follow keeps reading as lines are appended. lib/cmd_allowlist.sh runs

    python3 egress_log.py suggest LOG POLICY_DIR

which prints allowlist entries for the hosts in LOG that POLICY_DIR's
allowlist doesn't already cover.
"""

import collections
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import policy  # noqa: E402

PLACEHOLDER_PREFIX = "pjsb-placeholder-"

# Every column but the last is padded to this width; a longer value pushes
# the rest of its row over rather than being cut, so nothing is hidden.
COLUMNS = (("TIME", 24), ("DECISION", 10), ("METHOD", 7), ("HOST", 32), ("PATH", 32), ("RULE", 0))


def is_denied(entry):
    """Whether ENTRY was refused: a policy denial or a placeholder leak."""
    return entry.get("decision") == "deny"


def injected_profile(entry):
    """The profile whose token ENTRY injected, or None. Placeholders are
    named `pjsb-placeholder-<profile>`."""
    if entry.get("decision") != "inject":
        return None
    placeholder = str(entry.get("placeholder", ""))
    if placeholder.startswith(PLACEHOLDER_PREFIX):
        return placeholder[len(PLACEHOLDER_PREFIX):]
    return placeholder or "?"


def _row(cells):
    out = ""
    for (_, width), cell in zip(COLUMNS, cells):
        out += cell.ljust(width) + " " if width else cell
    return out.rstrip()


def header():
    return _row([name for name, _ in COLUMNS])


def format_row(entry):
    """ENTRY as one table row, with `injected: <profile>` after the rule."""
    rule = str(entry.get("rule", ""))
    profile = injected_profile(entry)
    if profile is not None:
        rule = "%s  injected: %s" % (rule, profile)
    return _row([str(entry.get(key, "")) for key in ("ts", "decision", "method", "host", "path")] + [rule])


def parse_line(line):
    """LINE's JSON object, or None if it isn't one (a torn or foreign line)."""
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    return entry if isinstance(entry, dict) else None


def lines(f, follow, poll=0.2):
    """F's lines; with FOLLOW, keeps waiting for more at the end of the file.
    A line still being written (no newline yet) is held until it's whole."""
    pending = ""
    while True:
        chunk = f.readline()
        if chunk:
            pending += chunk
            if pending.endswith("\n"):
                yield pending
                pending = ""
            continue
        if not follow:
            if pending:
                yield pending
            return
        time.sleep(poll)


def show(f, out, denied=False, follow=False, as_json=False):
    """Writes F's log to OUT as a table, or its raw lines with AS_JSON,
    keeping only refused requests with DENIED."""
    if not as_json:
        out.write(header() + "\n")
        out.flush()
    for n, line in enumerate(lines(f, follow), 1):
        if not line.strip():
            continue
        entry = parse_line(line)
        if entry is None:
            sys.stderr.write("egress.log:%d: not a JSON object, skipped\n" % n)
            continue
        if denied and not is_denied(entry):
            continue
        out.write(line if as_json else format_row(entry) + "\n")
        out.flush()


def suggest(f, rules, source):
    """Allowlist text for every host in log F that no rule in RULES names,
    sorted, each once, with its log line count as a comment. IP literals,
    and anything else the allowlist parser would refuse, are left out, so
    the text always parses."""
    counts = collections.Counter()
    for line in lines(f, follow=False):
        entry = parse_line(line)
        if entry is None or not isinstance(entry.get("host"), str):
            continue
        counts[policy.normalize_host(entry["host"])] += 1
    out = "# Suggested from %s; hosts only, so narrow by method or path by hand.\n" % source
    for host in sorted(counts):
        if not host or policy.is_ip_literal(host) or any(policy.host_matches(r.host, host) for r in rules):
            continue
        try:
            policy.parse_allowlist(host)
        except policy.AllowlistError:
            continue
        n = counts[host]
        out += "%s  # %d request%s\n" % (host, n, "" if n == 1 else "s")
    return out


def main(argv):
    if len(argv) == 4 and argv[1] == "suggest":
        try:
            rules = policy.load_allowlist(argv[3])
        except policy.AllowlistError as e:
            sys.stderr.write("egress_log.py: %s\n" % e)
            return 1
        with open(argv[2]) as f:
            sys.stdout.write(suggest(f, rules, argv[2]))
        return 0
    if len(argv) < 3 or argv[1] != "show":
        sys.stderr.write("usage: egress_log.py show LOG [--denied] [--follow] [--json]\n"
                         "       egress_log.py suggest LOG POLICY_DIR\n")
        return 2
    flags = set(argv[3:])
    unknown = flags - {"--denied", "--follow", "--json"}
    if unknown:
        sys.stderr.write("egress_log.py: unknown flag %s\n" % sorted(unknown)[0])
        return 2
    with open(argv[2]) as f:
        try:
            show(f, sys.stdout, "--denied" in flags, "--follow" in flags, "--json" in flags)
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
