"""Credential swap for the pj-sandbox proxy: placeholders in, real tokens out.

Standard library only (plus its sibling policy.py), so it can be unit-tested
without mitmproxy installed; addon.py calls it once policy has allowed a
request. The guest only ever holds placeholders such as
`pjsb-placeholder-gh`. For a request to a rule's host whose rule header
carries the rule's placeholder, as a bearer token or inside basic auth, the
placeholder is swapped for the real token. A placeholder seen anywhere in a
request to a host with no rule for it is denied as `placeholder-leak`.

Real tokens reach the proxy through its environment, one variable per
placeholder (see env_name), set by lib/tokens.sh. They never reach the log:
an injection logs the first 4 hex characters of the token's sha256 instead.

Run as `python3 inject.py sources POLICY_DIR` it prints `ENVNAME<TAB>SOURCE`
lines, every token source in the order to try, so the shell side never has
to parse JSON.
"""

import base64
import binascii
import collections
import hashlib
import json
import os
import re
import sys
import urllib.parse

import policy

SCHEMES = ("bearer", "basic")

InjectRule = collections.namedtuple("InjectRule", "host header scheme placeholder token_source")


def parse_rules(text):
    """The InjectRules in TEXT, a JSON array of {host, header, scheme,
    placeholder, token_source} objects. token_source is a non-empty list of
    `keychain:SERVICE/ACCOUNT`, `cmd:COMMAND` or `file:PATH` strings, tried
    in order. Anything malformed raises ValueError."""
    try:
        items = json.loads(text)
    except ValueError as e:
        raise ValueError("inject.json isn't JSON: %s" % e) from None
    if not isinstance(items, list):
        raise ValueError("inject.json must be a JSON array")
    rules = []
    for n, item in enumerate(items):
        if not isinstance(item, dict) or set(item) != set(InjectRule._fields):
            raise ValueError("inject.json rule %d needs exactly %s" % (n, ", ".join(InjectRule._fields)))
        if not all(isinstance(item[k], str) and item[k] for k in ("host", "header", "scheme", "placeholder")):
            raise ValueError("inject.json rule %d: host, header, scheme and placeholder must be strings" % n)
        if item["scheme"].lower() not in SCHEMES:
            raise ValueError("inject.json rule %d: scheme must be one of %s" % (n, ", ".join(SCHEMES)))
        sources = item["token_source"]
        if not isinstance(sources, list) or not sources or not all(
                isinstance(s, str) and re.match(r"^(keychain|cmd|file):.", s) for s in sources):
            raise ValueError("inject.json rule %d: token_source must be a non-empty list of "
                             "keychain:, cmd: or file: sources" % n)
        rules.append(InjectRule(policy.normalize_host(item["host"]), item["header"].lower(),
                                item["scheme"].lower(), item["placeholder"], tuple(sources)))
    return rules


def load_rules(policy_dir):
    """The InjectRules in POLICY_DIR/inject.json; none if it doesn't exist."""
    try:
        with open(os.path.join(policy_dir, "inject.json")) as f:
            return parse_rules(f.read())
    except FileNotFoundError:
        return []


def env_name(placeholder):
    """The environment variable that carries PLACEHOLDER's real token."""
    return "PJSB_TOKEN_" + re.sub(r"[^A-Z0-9]", "_", placeholder.upper())


def tokens_from_env(rules, environ):
    """{placeholder: token} for every placeholder in RULES; "" if unset."""
    return {r.placeholder: environ.get(env_name(r.placeholder), "") for r in rules}


def sources(rules):
    """(env name, source) pairs: each placeholder's sources in order, once."""
    pairs = []
    for rule in rules:
        for source in rule.token_source:
            pair = (env_name(rule.placeholder), source)
            if pair not in pairs:
                pairs.append(pair)
    return pairs


def fingerprint(token):
    """What the log holds in place of TOKEN: the first 4 hex of its sha256."""
    return hashlib.sha256(token.encode()).hexdigest()[:4]


def _decode_basic(value):
    """`user:password` from a `Basic ...` header VALUE, or None."""
    scheme, _, param = value.strip().partition(" ")
    if scheme.lower() != "basic":
        return None
    try:
        return base64.b64decode(param.strip(), validate=True).decode("utf-8", "replace")
    except (binascii.Error, ValueError):
        return None


def _views(host, path, headers):
    """Every string a placeholder could hide in: the URL raw and
    percent-decoded, and each header name and value, basic auth decoded."""
    views = [host, path, urllib.parse.unquote(path), urllib.parse.unquote_plus(path)]
    for name, value in headers:
        views += [name, value]
        decoded = _decode_basic(value)
        if decoded is not None:
            views.append(decoded)
    return views


class Injector:
    """Swaps placeholders for TOKENS ({placeholder: token}) under RULES,
    logging to LOG in policy.py's line format plus `placeholder` and, for an
    injection, `token_sha256`."""

    def __init__(self, task, mode, rules, tokens, log, clock=None):
        self.task = task
        self.mode = mode
        self.rules = list(rules)
        self.placeholders = sorted({r.placeholder for r in self.rules}, key=len, reverse=True)
        self.tokens = dict(tokens)
        self.log = log
        self.clock = clock or policy.utc_now

    def apply(self, scheme, host, method, path, headers):
        """(Decision, headers) for one request. HEADERS is a list of (name,
        value) pairs; the returned list has placeholders swapped where a rule
        allows. The Decision is `deny`/`placeholder-leak` if a placeholder
        is headed somewhere no rule sends it, `inject` if a token went in,
        `no-token` if a rule matched but no token was resolved, else `pass`
        (which isn't logged)."""
        host = policy.normalize_host(host)
        headers = list(headers)
        seen = [p for p in self.placeholders if any(p in v for v in _views(host, path, headers))]
        if not seen:
            return policy.Decision(True, "pass", ""), headers
        for placeholder in seen:
            if not any(r.placeholder == placeholder and policy.host_matches(r.host, host) for r in self.rules):
                return self._logged(policy.Decision(False, "deny", "placeholder-leak"),
                                    host, method, path, placeholder), headers

        decision, used = policy.Decision(True, "pass", ""), None
        for rule in self.rules:
            if not policy.host_matches(rule.host, host) or scheme != "https":
                continue
            for n, (name, value) in enumerate(headers):
                if name.lower() != rule.header:
                    continue
                swapped = self._swap(rule, value)
                if swapped is None:
                    continue
                token = self.tokens.get(rule.placeholder, "")
                if not token:
                    decision, used = policy.Decision(True, "no-token", rule.host), (rule.placeholder, None)
                    continue
                headers[n] = (name, swapped(token))
                decision, used = policy.Decision(True, "inject", rule.host), (rule.placeholder, token)
        if used is None:
            return decision, headers
        return self._logged(decision, host, method, path, used[0], used[1]), headers

    @staticmethod
    def _swap(rule, value):
        """A function of the token giving VALUE with RULE's placeholder
        swapped in, or None if VALUE doesn't carry it the rule's way."""
        word, _, param = value.strip().partition(" ")
        if rule.scheme == "bearer":
            if word.lower() == "bearer" and param.strip() == rule.placeholder:
                return lambda token: "%s %s" % (word, token)
            return None
        decoded = _decode_basic(value)
        if decoded is None or rule.placeholder not in decoded:
            return None
        return lambda token: "%s %s" % (word, base64.b64encode(
            decoded.replace(rule.placeholder, token).encode()).decode())

    def _logged(self, decision, host, method, path, placeholder, token=None):
        fields = {
            "ts": self.clock(),
            "task": self.task,
            "mode": self.mode,
            "host": host,
            "method": method.upper(),
            "path": path.split("?", 1)[0].split("#", 1)[0],
            "decision": decision.decision,
            "rule": decision.rule,
            "placeholder": placeholder,
        }
        if token:
            fields["token_sha256"] = fingerprint(token)
        self.log.write(json.dumps(fields) + "\n")
        if hasattr(self.log, "flush"):
            self.log.flush()
        return decision


def main(argv):
    if len(argv) != 3 or argv[1] != "sources":
        sys.stderr.write("usage: inject.py sources POLICY_DIR\n")
        return 2
    try:
        rules = load_rules(argv[2])
    except ValueError as e:
        sys.stderr.write("inject.py: %s\n" % e)
        return 1
    for name, source in sources(rules):
        print("%s\t%s" % (name, source))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
