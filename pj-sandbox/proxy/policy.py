"""Egress policy for the pj-sandbox proxy: allow or deny one request.

Standard library only, so it can be unit-tested without mitmproxy installed;
addon.py is the thin mitmproxy glue that calls it. It knows nothing about how
traffic reaches the proxy.
"""

import collections
import datetime
import ipaddress
import json
import os
import re
import socket
import urllib.parse

MODES = ("deny", "observe", "open")

Rule = collections.namedtuple("Rule", "host methods path source lineno text")
Decision = collections.namedtuple("Decision", "allowed decision rule")


class AllowlistError(ValueError):
    """A malformed allowlist line; the message starts `SOURCE:LINENO:`."""

    def __init__(self, source, lineno, message):
        super().__init__("%s:%d: %s" % (source, lineno, message))
        self.source = source
        self.lineno = lineno


_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_METHOD = re.compile(r"^[A-Z]+$")


def _is_hostname(name):
    labels = name.split(".")
    return len(name) <= 253 and all(_LABEL.match(label) for label in labels)


def _parse_host(field):
    """FIELD as a lowercased host pattern, or raises ValueError."""
    host = field.lower()
    if is_ip_literal(host):
        raise ValueError("%r is an IP address; allowlists take hostnames only" % field)
    if host.startswith("*."):
        suffix = host[2:]
        if "." not in suffix or not _is_hostname(suffix):
            raise ValueError("%r: a wildcard needs a suffix of at least two labels" % field)
        return host
    if not _is_hostname(host):
        raise ValueError("%r isn't a hostname or *.suffix pattern" % field)
    return host


def _parse_rule(line, source, lineno):
    """One allowlist LINE: `HOST [METHOD,...] [/PATH-PREFIX]`."""
    fields = line.split()
    if len(fields) > 3:
        raise ValueError("expected `HOST [METHOD,...] [/PATH]`, got %d fields" % len(fields))
    host = _parse_host(fields[0])
    methods = path = None
    for field in fields[1:]:
        if field.startswith("/"):
            if path is not None:
                raise ValueError("more than one path prefix")
            path = field
        else:
            if methods is not None or path is not None:
                raise ValueError("methods must come once, before the path: %r" % field)
            methods = frozenset(m.upper() for m in field.split(","))
            if not all(_METHOD.match(m) for m in methods):
                raise ValueError("%r isn't a comma-separated method list" % field)
    return Rule(host, methods, path, source, lineno, line)


def parse_allowlist(text, source="allowlist"):
    """Parses allowlist TEXT into a list of Rules.

    One rule per line, `HOST [METHOD,...] [/PATH-PREFIX]`, where HOST is an
    exact name or `*.suffix`. `#` starts a comment. A malformed line raises
    AllowlistError naming SOURCE and the line number, rather than being
    skipped, so a typo can't quietly drop a rule.
    """
    rules = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = re.sub(r"(^|\s)#.*$", "", line).strip()
        if not line:
            continue
        try:
            rules.append(_parse_rule(line, source, lineno))
        except ValueError as e:
            raise AllowlistError(source, lineno, str(e)) from None
    return rules


def load_allowlist(policy_dir):
    """The Rules in POLICY_DIR/allowlist; none if the file doesn't exist."""
    path = os.path.join(policy_dir, "allowlist")
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return []
    return parse_allowlist(text, source=path)


def normalize_host(host):
    """HOST lowercased, without a trailing dot or IPv6 brackets."""
    host = host.strip().lower().rstrip(".")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    return host


def is_ip_literal(host):
    """Whether HOST is an IP address rather than a name.

    Besides the usual IPv4 and IPv6 forms this catches the shorthand IPv4
    spellings resolvers still accept (`127.1`, `0x7f.1`, `2130706433`).
    """
    host = normalize_host(host)
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    try:
        socket.inet_aton(host)
        return True
    except OSError:
        return False


def host_matches(pattern, host):
    """Whether HOST (normalized) matches PATTERN: exact, or `*.suffix`.

    `*.suffix` matches subdomains at any depth but never the bare suffix, and
    the match is on a whole label, so `*.github.com` doesn't cover
    `evilgithub.com`.
    """
    if pattern.startswith("*."):
        return host.endswith(pattern[1:])
    return host == pattern


def path_matches(prefix, path):
    """Whether PATH (query and fragment ignored) starts with PREFIX.

    A path holding a `.` or `..` segment never matches, even percent-encoded
    or split by a backslash: the server resolves those after the check, so
    `/repos/..%5cuser` must not pass as being under `/repos/`.
    """
    path = path.split("?", 1)[0].split("#", 1)[0]
    segments = urllib.parse.unquote(path).replace("\\", "/").split("/")
    if any(segment in (".", "..") for segment in segments):
        return False
    return path.startswith(prefix)


class Policy:
    """Decides allow or deny for TASK's requests under MODE and RULES.

    `deny` passes only allowlisted requests; `observe` passes everything but
    marks what `deny` would have refused as `would-deny`; `open` passes
    everything.
    """

    def __init__(self, task, mode, rules, log, clock=None):
        if mode not in MODES:
            raise ValueError("unknown mode %r; expected one of %s" % (mode, ", ".join(MODES)))
        self.task = task
        self.mode = mode
        self.rules = list(rules)
        self.log = log
        self.clock = clock or utc_now

    def check(self, host, method, path):
        """The Decision for a METHOD request to HOST's PATH, logged."""
        host = normalize_host(host)
        allowlisted, rule = self._match(host, method, path)
        return self._decide(host, method.upper(), path, allowlisted, rule)

    def check_connect(self, host):
        """The Decision for a CONNECT tunnel to HOST, logged.

        Method and path aren't known until the tunnel is decrypted, so a host
        passes if any rule names it; check() narrows each request inside.
        """
        host = normalize_host(host)
        if is_ip_literal(host):
            allowlisted, rule = False, "ip-literal"
        else:
            matching = [r for r in self.rules if host_matches(r.host, host)]
            allowlisted = bool(matching)
            rule = _rule_name(matching[0]) if matching else "no-match"
        return self._decide(host, "CONNECT", "", allowlisted, rule)

    def _match(self, host, method, path):
        """(allowlisted, rule) for one request, ignoring the mode."""
        if is_ip_literal(host):
            return False, "ip-literal"
        for rule in self.rules:
            if not host_matches(rule.host, host):
                continue
            if rule.methods is not None and method.upper() not in rule.methods:
                continue
            if rule.path is not None and not path_matches(rule.path, path):
                continue
            return True, _rule_name(rule)
        return False, "no-match"

    def _decide(self, host, method, path, allowlisted, rule):
        if allowlisted:
            decision = Decision(True, "allow", rule)
        elif self.mode == "observe":
            decision = Decision(True, "would-deny", rule)
        elif self.mode == "open":
            decision = Decision(True, "allow", "open-mode")
        else:
            decision = Decision(False, "deny", rule)
        self._log(host, method, path, decision)
        return decision

    def _log(self, host, method, path, decision):
        """Writes DECISION as one JSON line. The query string is left out of
        the path, since that's where tokens ride."""
        line = json.dumps({
            "ts": self.clock(),
            "task": self.task,
            "mode": self.mode,
            "host": host,
            "method": method,
            "path": path.split("?", 1)[0].split("#", 1)[0],
            "decision": decision.decision,
            "rule": decision.rule,
        })
        self.log.write(line + "\n")
        if hasattr(self.log, "flush"):
            self.log.flush()


def _rule_name(rule):
    """How RULE is named in a Decision: `SOURCE:LINENO TEXT`."""
    return "%s:%d %s" % (rule.source, rule.lineno, rule.text)


def utc_now():
    """The current UTC time as ISO 8601 with a `Z` suffix."""
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.isoformat(timespec="milliseconds").replace("+00:00", "Z")
