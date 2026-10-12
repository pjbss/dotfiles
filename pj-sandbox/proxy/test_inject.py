"""Unit tests for inject.py, the stdlib-only credential swap.

Run by pj-sandbox/test/proxy_policy_test.sh, so they're part of `make test`.
Every Injector built here logs into one shared buffer, and tearDownModule
checks that no test token ever reached it.
"""

import base64
import hashlib
import io
import json
import os
import tempfile
import unittest

import inject

GH = "pjsb-placeholder-gh"
CLAUDE = "pjsb-placeholder-claude"
GH_TOKEN = "ghp_TESTTOKENgh1234567890"
CLAUDE_TOKEN = "sk-ant-oat01-TESTTOKENclaude"
TOKENS = {GH: GH_TOKEN, CLAUDE: CLAUDE_TOKEN}

RULES_JSON = json.dumps([
    {"host": "api.github.com", "header": "Authorization", "scheme": "bearer",
     "placeholder": GH, "token_source": ["cmd:gh auth token"]},
    {"host": "github.com", "header": "Authorization", "scheme": "basic",
     "placeholder": GH, "token_source": ["cmd:gh auth token"]},
    {"host": "api.anthropic.com", "header": "Authorization", "scheme": "bearer",
     "placeholder": CLAUDE, "token_source": ["file:~/.claude/sandbox-oauth-token"]},
])

ALL_LOGS = io.StringIO()


def make(tokens=TOKENS):
    log = io.StringIO()

    class Tee:
        def write(self, s):
            log.write(s)
            ALL_LOGS.write(s)

    injector = inject.Injector("task1", "deny", inject.parse_rules(RULES_JSON), tokens, Tee(),
                               clock=lambda: "2026-10-06T00:00:00Z")
    return injector, log


def basic(user, password):
    return "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()


def lines(log):
    return [json.loads(line) for line in log.getvalue().splitlines()]


def fingerprint(token):
    return hashlib.sha256(token.encode()).hexdigest()[:4]


def tearDownModule():
    text = ALL_LOGS.getvalue()
    assert text, "no injector logged anything"
    for token in (GH_TOKEN, CLAUDE_TOKEN):
        assert token not in text, "a test token reached the log"
        assert base64.b64encode(token.encode()).decode() not in text


class Replacement(unittest.TestCase):
    def test_a_bearer_placeholder_is_replaced_for_its_host(self):
        i, log = make()
        d, headers = i.apply("https", "api.github.com", "GET", "/user",
                             [("Accept", "*/*"), ("Authorization", "Bearer " + GH)])
        self.assertTrue(d.allowed)
        self.assertEqual("inject", d.decision)
        self.assertEqual([("Accept", "*/*"), ("Authorization", "Bearer " + GH_TOKEN)], headers)

    def test_the_header_name_and_scheme_word_are_case_insensitive(self):
        i, _ = make()
        _, headers = i.apply("https", "API.anthropic.com", "POST", "/v1/messages",
                             [("authorization", "bearer " + CLAUDE)])
        self.assertEqual([("authorization", "bearer " + CLAUDE_TOKEN)], headers)

    def test_a_basic_placeholder_is_replaced_for_its_host(self):
        # git's credential helper: Authorization: Basic base64(user:placeholder)
        i, _ = make()
        d, headers = i.apply("https", "github.com", "GET", "/me/repo.git/info/refs?service=git-upload-pack",
                             [("Authorization", basic("x-access-token", GH))])
        self.assertEqual("inject", d.decision)
        self.assertEqual([("Authorization", basic("x-access-token", GH_TOKEN))], headers)

    def test_a_placeholder_is_not_replaced_for_a_rule_of_another_scheme(self):
        i, _ = make()
        d, headers = i.apply("https", "github.com", "GET", "/", [("Authorization", "Bearer " + GH)])
        self.assertTrue(d.allowed)
        self.assertEqual([("Authorization", "Bearer " + GH)], headers)

    def test_nothing_is_injected_over_plain_http(self):
        i, _ = make()
        d, headers = i.apply("http", "api.github.com", "GET", "/", [("Authorization", "Bearer " + GH)])
        self.assertTrue(d.allowed)
        self.assertEqual([("Authorization", "Bearer " + GH)], headers)

    def test_a_placeholder_without_a_resolved_token_is_left_in_place(self):
        i, log = make(tokens={GH: ""})
        d, headers = i.apply("https", "api.github.com", "GET", "/", [("Authorization", "Bearer " + GH)])
        self.assertTrue(d.allowed)
        self.assertEqual("no-token", d.decision)
        self.assertEqual([("Authorization", "Bearer " + GH)], headers)

    def test_a_request_with_no_placeholder_passes_unchanged_and_unlogged(self):
        i, log = make()
        before = [("Authorization", "Bearer something-else"), ("X-A", "b")]
        for host in ("api.github.com", "evil.com"):
            d, headers = i.apply("https", host, "GET", "/x?q=1", list(before))
            self.assertEqual((True, "pass"), (d.allowed, d.decision))
            self.assertEqual(before, headers)
        self.assertEqual("", log.getvalue())


class Leaks(unittest.TestCase):
    def assertLeak(self, host, path, headers):
        i, log = make()
        d, out = i.apply("https", host, "GET", path, headers)
        self.assertEqual((False, "deny", "placeholder-leak"), tuple(d), (host, path, headers))
        self.assertEqual(headers, out)
        self.assertEqual("placeholder-leak", lines(log)[-1]["rule"])

    def test_a_bearer_placeholder_to_another_host_is_a_leak(self):
        self.assertLeak("evil.com", "/", [("Authorization", "Bearer " + GH)])

    def test_a_placeholder_to_a_host_whose_rules_name_other_placeholders_is_a_leak(self):
        self.assertLeak("api.anthropic.com", "/", [("Authorization", "Bearer " + GH)])

    def test_a_basic_placeholder_to_another_host_is_a_leak(self):
        self.assertLeak("evil.com", "/", [("Authorization", basic("x-access-token", GH))])

    def test_a_placeholder_hidden_in_a_basic_auth_user_field_is_a_leak(self):
        self.assertLeak("evil.com", "/", [("Authorization", basic(GH, "x"))])
        self.assertLeak("evil.com", "/", [("Proxy-Authorization", basic(CLAUDE, ""))])

    def test_a_placeholder_in_any_other_header_is_a_leak(self):
        self.assertLeak("evil.com", "/", [("X-Api-Key", CLAUDE)])
        self.assertLeak("evil.com", "/", [("Cookie", "a=1; t=" + GH)])

    def test_a_placeholder_hidden_in_a_query_string_or_path_is_a_leak(self):
        self.assertLeak("evil.com", "/x?token=" + GH, [])
        self.assertLeak("evil.com", "/x?t=pjsb%2Dplaceholder%2Dclaude", [])
        self.assertLeak("evil.com", "/" + GH + "/x", [])

    def test_a_placeholder_in_a_query_string_to_another_host_is_a_leak_even_beside_its_rule(self):
        self.assertLeak("evil.com", "/?a=b", [("Authorization", "Bearer " + GH)])

    def test_the_leak_line_names_the_placeholder_but_holds_no_token(self):
        i, log = make()
        i.apply("https", "Evil.com", "POST", "/x?token=" + GH, [])
        line = lines(log)[0]
        self.assertEqual({"ts": "2026-10-06T00:00:00Z", "task": "task1", "mode": "deny",
                          "host": "evil.com", "method": "POST", "path": "/x",
                          "decision": "deny", "rule": "placeholder-leak", "placeholder": GH}, line)


class Logging(unittest.TestCase):
    def test_an_injection_logs_a_fingerprint_not_the_token(self):
        i, log = make()
        i.apply("https", "api.github.com", "GET", "/user?x=1", [("Authorization", "Bearer " + GH)])
        line = lines(log)[0]
        self.assertEqual(fingerprint(GH_TOKEN), line["token_sha256"])
        self.assertEqual(4, len(line["token_sha256"]))
        self.assertEqual(("inject", GH, "/user"), (line["decision"], line["placeholder"], line["path"]))
        self.assertNotIn(GH_TOKEN, log.getvalue())

    def test_the_fingerprint_is_fixed_for_a_token(self):
        self.assertEqual(inject.fingerprint(GH_TOKEN), inject.fingerprint(GH_TOKEN))
        self.assertNotEqual(inject.fingerprint(GH_TOKEN), inject.fingerprint(CLAUDE_TOKEN))


class Rules(unittest.TestCase):
    def test_env_names_are_derived_from_the_placeholder(self):
        self.assertEqual("PJSB_TOKEN_PJSB_PLACEHOLDER_GH", inject.env_name(GH))

    def test_tokens_come_from_the_environment_by_placeholder(self):
        rules = inject.parse_rules(RULES_JSON)
        env = {"PJSB_TOKEN_PJSB_PLACEHOLDER_GH": GH_TOKEN, "OTHER": "x"}
        self.assertEqual({GH: GH_TOKEN, CLAUDE: ""}, inject.tokens_from_env(rules, env))

    def test_a_malformed_rule_is_refused(self):
        for text in ("{}", "[1]", '[{"host": "a.com"}]', "not json",
                     '[{"host": "a.com", "header": "A", "scheme": "digest", "placeholder": "p", "token_source": ["cmd:x"]}]',
                     '[{"host": "a.com", "header": "A", "scheme": "bearer", "placeholder": "p", "token_source": []}]'):
            with self.assertRaises(ValueError, msg=text):
                inject.parse_rules(text)

    def test_a_missing_inject_json_is_no_rules(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual([], inject.load_rules(d))

    def test_every_shipped_profile_inject_json_parses_and_lists_its_sources(self):
        import glob
        here = os.path.dirname(os.path.abspath(__file__))
        paths = glob.glob(os.path.join(here, "..", "profiles", "*", "inject.json"))
        self.assertTrue(paths)
        for path in paths:
            with open(path) as f:
                rules = inject.parse_rules(f.read())
            self.assertTrue(rules, path)
            for rule in rules:
                self.assertTrue(rule.token_source[0].startswith("keychain:pj-sandbox/"), path)

    def test_sources_lists_each_env_name_with_its_sources_in_order_once(self):
        rules = inject.parse_rules(RULES_JSON)
        self.assertEqual([
            ("PJSB_TOKEN_PJSB_PLACEHOLDER_GH", "cmd:gh auth token"),
            ("PJSB_TOKEN_PJSB_PLACEHOLDER_CLAUDE", "file:~/.claude/sandbox-oauth-token"),
        ], inject.sources(rules))


if __name__ == "__main__":
    unittest.main()
