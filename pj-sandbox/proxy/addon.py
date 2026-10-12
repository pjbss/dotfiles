"""mitmproxy glue for the pj-sandbox egress policy.

The only module here that imports mitmproxy; every decision is policy.py's.
Load it with:

    mitmdump -s pj-sandbox/proxy/addon.py \
        --set pjsb_policy_dir=<state dir>/<task>/policy --set pjsb_mode=deny

The task's name is the policy dir's parent, and decisions are appended to
`<state dir>/<task>/egress.log`. Once policy allows a request, inject.py
swaps the guest's placeholders for the real tokens in the proxy's
environment (set by lib/tokens.sh), or denies a placeholder headed somewhere
`policy/inject.json` doesn't send it. A denied request or CONNECT gets a 403
with a one-line reason. A malformed allowlist or inject.json, or an unknown
mode, stops mitmdump from starting, and an error while deciding denies, so
the proxy fails closed.
"""

import os
import sys

from mitmproxy import ctx, exceptions, http

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inject  # noqa: E402
import policy  # noqa: E402


class PolicyAddon:
    def __init__(self):
        self.policy = None
        self.injector = None
        self.log = None

    def load(self, loader):
        loader.add_option("pjsb_policy_dir", str, "", "The task's policy/ dir (holds `allowlist`).")
        loader.add_option("pjsb_mode", str, "deny", "Egress mode: deny, observe or open.")

    def configure(self, updated):
        if not {"pjsb_policy_dir", "pjsb_mode"} & set(updated):
            return
        policy_dir = ctx.options.pjsb_policy_dir
        if not policy_dir:
            raise exceptions.OptionsError("pjsb_policy_dir is required")
        policy_dir = os.path.abspath(policy_dir)
        task_dir = os.path.dirname(policy_dir)
        try:
            rules = policy.load_allowlist(policy_dir)
            inject_rules = inject.load_rules(policy_dir)
            if ctx.options.pjsb_mode not in policy.MODES:
                raise ValueError("pjsb_mode must be one of %s" % ", ".join(policy.MODES))
        except ValueError as e:
            raise exceptions.OptionsError(str(e)) from None
        self.done()
        self.log = open(os.path.join(task_dir, "egress.log"), "a")
        task, mode = os.path.basename(task_dir), ctx.options.pjsb_mode
        self.policy = policy.Policy(task, mode, rules, self.log)
        tokens = inject.tokens_from_env(inject_rules, os.environ)
        self.injector = inject.Injector(task, mode, inject_rules, tokens, self.log)

    def done(self):
        if self.log is not None:
            self.log.close()
            self.log = None

    def http_connect(self, flow):
        self._enforce(flow, lambda: self.policy.check_connect(flow.request.host))

    def request(self, flow):
        # request.host is where the proxy will actually connect, unlike the
        # Host header, which the client can set to anything.
        req = flow.request
        self._enforce(flow, lambda: self.policy.check(req.host, req.method, req.path))
        if flow.response is None:
            self._enforce(flow, lambda: self._inject(req))

    def _inject(self, req):
        before = list(req.headers.items(multi=True))
        decision, after = self.injector.apply(req.scheme, req.host, req.method, req.path, before)
        if after != before:
            req.headers = http.Headers([(k.encode("utf-8", "surrogateescape"), v.encode("utf-8", "surrogateescape"))
                                        for k, v in after])
        return decision

    def _enforce(self, flow, decide):
        try:
            decision = decide()
        except Exception as e:  # fail closed: mitmproxy would let the flow through
            decision = policy.Decision(False, "deny", "error: %s" % type(e).__name__)
        if not decision.allowed:
            reason = "pj-sandbox: %s blocked by egress policy (%s)\n" % (flow.request.host, decision.rule)
            flow.response = http.Response.make(403, reason.encode(), {"Content-Type": "text/plain"})


addons = [PolicyAddon()]
