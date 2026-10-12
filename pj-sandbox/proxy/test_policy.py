"""Unit tests for policy.py, the stdlib-only egress policy engine.

Run by pj-sandbox/test/proxy_policy_test.sh, so they're part of `make test`.
"""

import io
import json
import os
import unittest

import policy


def make(allowlist, mode="deny"):
    """A Policy over ALLOWLIST text, logging into a StringIO it returns too."""
    log = io.StringIO()
    rules = policy.parse_allowlist(allowlist)
    p = policy.Policy("task1", mode, rules, log, clock=lambda: "2026-10-06T00:00:00Z")
    return p, log


class HostMatching(unittest.TestCase):
    def test_exact_host_is_allowed_and_others_denied(self):
        p, _ = make("api.github.com\n")
        self.assertTrue(p.check("api.github.com", "GET", "/").allowed)
        self.assertFalse(p.check("github.com", "GET", "/").allowed)

    def test_host_comparison_ignores_case_and_a_trailing_dot(self):
        p, _ = make("api.github.com\n")
        self.assertTrue(p.check("API.GitHub.com.", "GET", "/").allowed)

    def test_suffix_rule_matches_subdomains_at_any_depth(self):
        p, _ = make("*.github.com\n")
        self.assertTrue(p.check("api.github.com", "GET", "/").allowed)
        self.assertTrue(p.check("a.b.github.com", "GET", "/").allowed)

    def test_suffix_rule_does_not_match_a_bare_lookalike(self):
        p, _ = make("*.github.com\n")
        self.assertFalse(p.check("evilgithub.com", "GET", "/").allowed)
        self.assertFalse(p.check("github.com.evil.com", "GET", "/").allowed)

    def test_suffix_rule_does_not_match_the_bare_suffix_itself(self):
        p, _ = make("*.github.com\n")
        self.assertFalse(p.check("github.com", "GET", "/").allowed)


class Narrowing(unittest.TestCase):
    def test_method_list_narrows_a_host(self):
        p, _ = make("api.github.com GET,HEAD\n")
        self.assertTrue(p.check("api.github.com", "GET", "/x").allowed)
        self.assertTrue(p.check("api.github.com", "head", "/x").allowed)
        self.assertFalse(p.check("api.github.com", "POST", "/x").allowed)

    def test_path_prefix_narrows_a_host(self):
        p, _ = make("api.github.com /repos/me/\n")
        self.assertTrue(p.check("api.github.com", "POST", "/repos/me/proj/pulls").allowed)
        self.assertFalse(p.check("api.github.com", "GET", "/user").allowed)

    def test_method_and_path_narrow_together(self):
        p, _ = make("api.github.com GET /repos/\n")
        self.assertTrue(p.check("api.github.com", "GET", "/repos/x").allowed)
        self.assertFalse(p.check("api.github.com", "DELETE", "/repos/x").allowed)
        self.assertFalse(p.check("api.github.com", "GET", "/user").allowed)

    def test_query_string_is_not_part_of_the_path_match(self):
        p, _ = make("api.github.com /repos/\n")
        self.assertTrue(p.check("api.github.com", "GET", "/repos/x?a=/user").allowed)
        self.assertTrue(p.check("api.github.com", "GET", "/repos/x?next=/../y").allowed)
        self.assertFalse(p.check("api.github.com", "GET", "/user?/repos/").allowed)

    def test_dot_segments_cannot_climb_out_of_a_path_prefix(self):
        p, _ = make("api.github.com /repos/\n")
        for path in ("/repos/../user", "/repos/%2e%2e/user", "/repos/.%2E/user",
                     "/repos/..%2fuser", "/repos/x%2F..%2F..%2Fuser",
                     "/repos/..%5cuser", "/repos/..\\user"):
            self.assertFalse(p.check("api.github.com", "GET", path).allowed, path)

    def test_an_encoded_slash_without_dot_segments_still_matches(self):
        p, _ = make("api.github.com /repos/\n")
        self.assertTrue(p.check("api.github.com", "GET", "/repos/o/r/branches/feat%2Fx").allowed)

    def test_a_later_rule_can_allow_what_an_earlier_narrower_one_did_not(self):
        p, _ = make("api.github.com GET\napi.github.com POST /graphql\n")
        self.assertTrue(p.check("api.github.com", "POST", "/graphql").allowed)
        self.assertFalse(p.check("api.github.com", "POST", "/user").allowed)


class IpLiterals(unittest.TestCase):
    LITERALS = ("140.82.112.3", "127.0.0.1", "[::1]", "::ffff:140.82.112.3",
                "2130706433", "0x7f.1", "127.1")

    def test_ip_literals_are_recognized(self):
        for host in self.LITERALS:
            self.assertTrue(policy.is_ip_literal(host), host)
        for host in ("github.com", "1password.com", "x.0x7f.example"):
            self.assertFalse(policy.is_ip_literal(host), host)

    def test_ip_literal_destinations_are_denied_in_deny_mode(self):
        p, _ = make("*.github.com\n")
        for host in self.LITERALS:
            d = p.check(host, "GET", "/")
            self.assertEqual((False, "deny", "ip-literal"), tuple(d), host)

    def test_ip_literal_is_denied_even_if_a_rule_would_match_it(self):
        # parse_allowlist refuses IPs, so build the rule by hand.
        rule = policy.Rule("127.0.0.1", None, None, "allowlist", 1, "127.0.0.1")
        p = policy.Policy("task1", "deny", [rule], io.StringIO())
        self.assertFalse(p.check("127.0.0.1", "GET", "/").allowed)


class Modes(unittest.TestCase):
    def test_deny_mode_passes_only_allowlisted_requests(self):
        p, _ = make("github.com\n", mode="deny")
        self.assertEqual("allow", p.check("github.com", "GET", "/").decision)
        self.assertEqual((False, "deny", "no-match"), tuple(p.check("evil.com", "GET", "/")))

    def test_observe_mode_passes_everything_and_marks_would_deny(self):
        p, _ = make("github.com\n", mode="observe")
        self.assertEqual((True, "allow", "allowlist:1 github.com"),
                         tuple(p.check("github.com", "GET", "/")))
        self.assertEqual((True, "would-deny", "no-match"), tuple(p.check("evil.com", "GET", "/")))
        self.assertEqual((True, "would-deny", "ip-literal"), tuple(p.check("10.0.0.1", "GET", "/")))

    def test_open_mode_passes_everything(self):
        p, _ = make("github.com\n", mode="open")
        self.assertEqual((True, "allow", "allowlist:1 github.com"),
                         tuple(p.check("github.com", "GET", "/")))
        self.assertEqual((True, "allow", "open-mode"), tuple(p.check("evil.com", "GET", "/")))
        self.assertEqual((True, "allow", "open-mode"), tuple(p.check("10.0.0.1", "GET", "/")))

    def test_an_unknown_mode_is_refused(self):
        with self.assertRaises(ValueError):
            make("github.com\n", mode="allow-all")


class AllowlistParsing(unittest.TestCase):
    def test_comments_and_blank_lines_are_skipped(self):
        rules = policy.parse_allowlist("# hosts\n\n  github.com   # the site\n")
        self.assertEqual(1, len(rules))
        self.assertEqual(("github.com", 3), (rules[0].host, rules[0].lineno))

    def test_malformed_lines_are_rejected_with_their_line_number(self):
        bad = (
            "*",                           # no suffix
            "*.com",                       # a whole TLD
            "foo.*.com",                   # wildcard not leading
            "https://github.com",          # a URL, not a host
            "github.com:443",              # a port
            "a..github.com",               # empty label
            "-x.github.com",               # label starting with a hyphen
            "140.82.112.3",                # IPs are never allowlisted
            "github.com G3T",              # bad method
            "github.com GET POST",         # two method fields
            "github.com /a /b",            # two paths
            "github.com GET /a extra",     # too many fields
        )
        for line in bad:
            text = "github.com\n# fine\n" + line + "\n"
            with self.assertRaises(policy.AllowlistError, msg=line) as caught:
                policy.parse_allowlist(text, source="policy/allowlist")
            self.assertIn("policy/allowlist:3:", str(caught.exception), line)
            self.assertEqual(3, caught.exception.lineno, line)

    def test_every_shipped_profile_allowlist_parses(self):
        import glob
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        paths = glob.glob(os.path.join(here, "..", "profiles", "*", "allowlist"))
        self.assertTrue(paths)
        for path in paths:
            with open(path) as f:
                self.assertTrue(policy.parse_allowlist(f.read(), source=path), path)

    def test_load_allowlist_reads_the_policy_dirs_file(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "allowlist"), "w") as f:
                f.write("github.com\nbad..host\n")
            with self.assertRaises(policy.AllowlistError) as caught:
                policy.load_allowlist(d)
            self.assertIn(os.path.join(d, "allowlist") + ":2:", str(caught.exception))

    def test_a_missing_allowlist_is_empty_so_deny_mode_denies_everything(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual([], policy.load_allowlist(d))


FIELDS = {"ts", "task", "mode", "host", "method", "path", "decision", "rule"}


def log_lines(log):
    return [json.loads(line) for line in log.getvalue().splitlines()]


class Logging(unittest.TestCase):
    def test_every_decision_writes_exactly_one_json_line_with_every_field(self):
        for mode in policy.MODES:
            p, log = make("github.com GET\n", mode=mode)
            calls = [
                lambda: p.check("github.com", "GET", "/a"),
                lambda: p.check("github.com", "POST", "/a"),
                lambda: p.check("evil.com", "GET", "/"),
                lambda: p.check("10.0.0.1", "GET", "/"),
                lambda: p.check_connect("github.com"),
                lambda: p.check_connect("evil.com"),
            ]
            for n, call in enumerate(calls, 1):
                call()
                lines = log_lines(log)
                self.assertEqual(n, len(lines), mode)
                self.assertEqual(FIELDS, set(lines[-1]), mode)

    def test_the_line_records_the_decision(self):
        p, log = make("github.com GET\n", mode="observe")
        p.check("Evil.com", "post", "/x?token=s3cret")
        self.assertEqual({
            "ts": "2026-10-06T00:00:00Z", "task": "task1", "mode": "observe",
            "host": "evil.com", "method": "POST", "path": "/x",
            "decision": "would-deny", "rule": "no-match",
        }, log_lines(log)[0])

    def test_query_strings_never_reach_the_log(self):
        p, log = make("github.com\n")
        p.check("github.com", "GET", "/a?access_token=s3cret#frag")
        self.assertNotIn("s3cret", log.getvalue())

    def test_the_default_clock_is_utc_iso8601(self):
        log = io.StringIO()
        policy.Policy("t", "deny", [], log).check("x.com", "GET", "/")
        self.assertRegex(log_lines(log)[0]["ts"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$")


class Connect(unittest.TestCase):
    def test_connect_passes_a_host_any_rule_names_even_when_narrowed(self):
        # Method and path are only known once the tunnel is decrypted, so
        # they're checked per request, not at CONNECT.
        p, log = make("api.github.com GET /repos/\n")
        self.assertTrue(p.check_connect("api.github.com").allowed)
        self.assertFalse(p.check_connect("evil.com").allowed)
        self.assertEqual(("CONNECT", ""), (log_lines(log)[0]["method"], log_lines(log)[0]["path"]))

    def test_connect_to_an_ip_literal_is_denied(self):
        p, _ = make("*.github.com\n")
        self.assertEqual((False, "deny", "ip-literal"), tuple(p.check_connect("140.82.112.3")))

    def test_connect_follows_the_mode(self):
        p, _ = make("github.com\n", mode="observe")
        self.assertEqual((True, "would-deny", "no-match"), tuple(p.check_connect("evil.com")))


def imported_modules(path):
    """The top-level names of every absolute import in the source at PATH,
    wherever it appears (functions and try blocks included)."""
    import ast
    with open(path) as f:
        tree = ast.parse(f.read(), path)
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0:
            names.add(node.module.split(".")[0])
    return names


class Imports(unittest.TestCase):
    def setUp(self):
        import glob
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        self.sources = {os.path.basename(p): p for p in glob.glob(os.path.join(here, "*.py"))}
        self.siblings = {name[:-3] for name in self.sources}

    def test_the_import_scanner_sees_imports(self):
        self.assertIn("json", imported_modules(self.sources["policy.py"]))
        self.assertIn("mitmproxy", imported_modules(self.sources["addon.py"]))

    def test_policy_imports_only_the_standard_library(self):
        import sys
        extra = imported_modules(self.sources["policy.py"]) - set(sys.stdlib_module_names)
        self.assertEqual(set(), extra)

    def test_every_module_but_addon_is_stdlib_only(self):
        import sys
        allowed = set(sys.stdlib_module_names) | self.siblings
        for name, path in self.sources.items():
            if name == "addon.py":
                continue
            self.assertEqual(set(), imported_modules(path) - allowed, name)

    def test_addon_is_the_only_module_that_imports_mitmproxy(self):
        importers = {name for name, path in self.sources.items()
                     if "mitmproxy" in imported_modules(path)}
        self.assertEqual({"addon.py"}, importers)


def fake_mitmproxy():
    """Stand-in `mitmproxy` modules: just the surface addon.py touches, so the
    glue is testable without mitmproxy installed."""
    import types
    root = types.ModuleType("mitmproxy")
    http = types.ModuleType("mitmproxy.http")
    exceptions = types.ModuleType("mitmproxy.exceptions")

    class Response:
        @classmethod
        def make(cls, status_code, content, headers):
            r = cls()
            r.status_code, r.content, r.headers = status_code, content, headers
            return r

    class OptionsError(Exception):
        pass

    class Headers:
        def __init__(self, fields=()):
            self.fields = tuple(fields)

        def items(self, multi=False):
            return [(k.decode(), v.decode()) for k, v in self.fields]

    http.Response = Response
    http.Headers = Headers
    exceptions.OptionsError = OptionsError
    root.http, root.exceptions = http, exceptions
    root.ctx = types.SimpleNamespace(options=types.SimpleNamespace())
    return {"mitmproxy": root, "mitmproxy.http": http, "mitmproxy.exceptions": exceptions}


class Addon(unittest.TestCase):
    def setUp(self):
        import importlib
        import os
        import sys
        import tempfile
        from unittest import mock
        self.modules = fake_mitmproxy()
        patcher = mock.patch.dict(sys.modules, self.modules)
        patcher.start()
        self.addCleanup(patcher.stop)
        sys.modules.pop("addon", None)
        self.addon_module = importlib.import_module("addon")
        self.addCleanup(sys.modules.pop, "addon", None)

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.task_dir = os.path.join(tmp.name, "state", "task1")
        self.policy_dir = os.path.join(self.task_dir, "policy")
        os.makedirs(self.policy_dir)
        self.write_allowlist("github.com GET\n")

    def write_allowlist(self, text):
        import os
        with open(os.path.join(self.policy_dir, "allowlist"), "w") as f:
            f.write(text)

    def configured(self, mode="deny"):
        options = self.modules["mitmproxy"].ctx.options
        options.pjsb_policy_dir, options.pjsb_mode = self.policy_dir, mode
        addon = self.addon_module.PolicyAddon()
        addon.configure({"pjsb_policy_dir", "pjsb_mode"})
        self.addCleanup(addon.done)
        return addon

    def write_inject(self, rules):
        import os
        with open(os.path.join(self.policy_dir, "inject.json"), "w") as f:
            f.write(rules if isinstance(rules, str) else json.dumps(rules))

    def flow(self, host, method="GET", path="/", headers=(), scheme="https"):
        import types
        Headers = self.modules["mitmproxy.http"].Headers
        fields = [(k.encode(), v.encode()) for k, v in headers]
        request = types.SimpleNamespace(host=host, method=method, path=path, scheme=scheme,
                                        headers=Headers(fields))
        return types.SimpleNamespace(request=request, response=None)

    def egress_log(self):
        import os
        with open(os.path.join(self.task_dir, "egress.log")) as f:
            return [json.loads(line) for line in f]

    def test_addons_list_holds_the_policy_addon(self):
        self.assertIsInstance(self.addon_module.addons[0], self.addon_module.PolicyAddon)

    def test_it_registers_the_policy_dir_and_mode_options(self):
        added = {}
        loader = type("Loader", (), {"add_option": lambda s, name, typespec, default, help: added.update({name: default})})()
        self.addon_module.PolicyAddon().load(loader)
        self.assertEqual({"pjsb_policy_dir": "", "pjsb_mode": "deny"}, added)

    def test_a_denied_request_gets_a_403_with_a_short_reason(self):
        addon = self.configured()
        f = self.flow("evil.com")
        addon.request(f)
        self.assertEqual(403, f.response.status_code)
        self.assertIn(b"evil.com", f.response.content)
        self.assertIn(b"no-match", f.response.content)

    def test_an_allowed_request_is_left_alone(self):
        addon = self.configured()
        f = self.flow("github.com")
        addon.request(f)
        self.assertIsNone(f.response)

    def test_a_denied_connect_gets_a_403_and_an_allowed_one_passes(self):
        addon = self.configured()
        denied, allowed = self.flow("evil.com", "CONNECT", ""), self.flow("github.com", "CONNECT", "")
        addon.http_connect(denied)
        addon.http_connect(allowed)
        self.assertEqual(403, denied.response.status_code)
        self.assertIsNone(allowed.response)

    def test_decisions_go_to_the_tasks_egress_log(self):
        addon = self.configured(mode="observe")
        addon.request(self.flow("evil.com", "POST", "/x"))
        line = self.egress_log()[0]
        self.assertEqual(("task1", "observe", "would-deny"), (line["task"], line["mode"], line["decision"]))

    def test_a_malformed_allowlist_stops_the_proxy_from_starting(self):
        self.write_allowlist("github.com\n1.2.3.4\n")
        with self.assertRaises(self.modules["mitmproxy.exceptions"].OptionsError) as caught:
            self.configured()
        self.assertIn("allowlist:2:", str(caught.exception))

    def test_a_bad_mode_or_missing_policy_dir_stops_the_proxy_from_starting(self):
        OptionsError = self.modules["mitmproxy.exceptions"].OptionsError
        with self.assertRaises(OptionsError):
            self.configured(mode="allow-all")
        self.policy_dir = ""
        with self.assertRaises(OptionsError):
            self.configured()

    GH_RULE = {"host": "github.com", "header": "Authorization", "scheme": "bearer",
               "placeholder": "pjsb-placeholder-gh", "token_source": ["cmd:gh auth token"]}

    def with_token(self, value):
        import os
        from unittest import mock
        patcher = mock.patch.dict(os.environ, {"PJSB_TOKEN_PJSB_PLACEHOLDER_GH": value})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_an_allowed_request_gets_its_placeholder_swapped(self):
        self.write_inject([self.GH_RULE])
        self.with_token("ghp_ADDONTEST")
        addon = self.configured()
        f = self.flow("github.com", headers=[("Authorization", "Bearer pjsb-placeholder-gh")])
        addon.request(f)
        self.assertIsNone(f.response)
        self.assertEqual([("Authorization", "Bearer ghp_ADDONTEST")], f.request.headers.items(multi=True))
        line = self.egress_log()[-1]
        self.assertEqual(("inject", "pjsb-placeholder-gh"), (line["decision"], line["placeholder"]))
        with open(os.path.join(self.task_dir, "egress.log")) as log:
            self.assertNotIn("ghp_ADDONTEST", log.read())

    def test_a_placeholder_leak_to_an_allowlisted_host_gets_a_403(self):
        self.write_allowlist("github.com\nexample.com\n")
        self.write_inject([self.GH_RULE])
        self.with_token("ghp_ADDONTEST")
        addon = self.configured()
        f = self.flow("example.com", path="/?t=pjsb-placeholder-gh")
        addon.request(f)
        self.assertEqual(403, f.response.status_code)
        self.assertIn(b"placeholder-leak", f.response.content)
        self.assertEqual("placeholder-leak", self.egress_log()[-1]["rule"])

    def test_a_request_policy_denies_is_never_injected(self):
        self.write_inject([dict(self.GH_RULE, host="evil.com")])
        self.with_token("ghp_ADDONTEST")
        addon = self.configured()
        f = self.flow("evil.com", headers=[("Authorization", "Bearer pjsb-placeholder-gh")])
        addon.request(f)
        self.assertEqual(403, f.response.status_code)
        self.assertEqual([("Authorization", "Bearer pjsb-placeholder-gh")], f.request.headers.items(multi=True))

    def test_a_malformed_inject_json_stops_the_proxy_from_starting(self):
        self.write_inject("[{}]")
        with self.assertRaises(self.modules["mitmproxy.exceptions"].OptionsError) as caught:
            self.configured()
        self.assertIn("inject.json", str(caught.exception))

    def test_an_error_inside_the_policy_fails_closed(self):
        addon = self.configured(mode="open")
        f = self.flow(None)  # normalize_host(None) raises
        addon.request(f)
        self.assertEqual(403, f.response.status_code)


if __name__ == "__main__":
    unittest.main()
