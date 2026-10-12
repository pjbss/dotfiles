# CA and pinning spike

Whether each agent works through the credential-brokering proxy. That means
two things: it trusts the proxy's CA, and it accepts a placeholder token that
the proxy swaps for the real one (issues/prd-pj-sandbox.md, "CA and pinning
spike"; issue 010). An agent that pins certificates, or validates its token
locally, can't be brokered. Its profile then falls back to forwarding the real
token into the guest, as the old sandbox does, and is marked **unbrokered** in
`status` and `verify` output.

The tooling is `pj-sandbox/test/live/spike_ca.sh`, with its Lima config in
`pj-sandbox/lima/spike/ca.yaml`. It needs a real Mac host with Lima,
mitmproxy (`uv tool install mitmproxy`; the Homebrew cask is killed by Gatekeeper, see Findings) and real credentials, so it's run by
hand (MT-5 in `issues/manual-tests.md`).

## What it does

1. Generates a scratch CA in a `mktemp -d` on the host.
2. Starts `mitmdump` on the host (`127.0.0.1:8080`) with that CA and a small
   addon. The real tokens are exported into that one process's environment
   and nowhere else:
   - Claude: `~/.claude/sandbox-oauth-token`
   - GitHub (gh, git and Copilot): `gh auth token`

   For the target hosts only, the addon swaps a placeholder for the real token
   in `Authorization` (bearer, `token` or basic) or `x-api-key`. The log notes
   each rewrite, and any placeholder sent to a host that isn't a target.
3. Boots `pjsb-spike-ca`, which has no host mounts. It installs only the CA's
   certificate in the guest trust store, and sets `NODE_EXTRA_CA_CERTS` and
   `SSL_CERT_FILE`.
4. Runs each check in the guest with only placeholders set:
   `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`,
   `COPILOT_GITHUB_TOKEN`, and a git credential helper that answers with
   `GH_TOKEN`.
5. Deletes the VM, stops mitmdump and removes the scratch CA, whatever
   happened.

Commands:

    pj-sandbox/test/live/spike_ca.sh --dry-run --repo OWNER/PRIVATE-REPO
    pj-sandbox/test/live/spike_ca.sh --repo OWNER/PRIVATE-REPO

Use a private repo for `[git]`. A public one answers `ls-remote` with no
credentials, so an OK proves nothing. Raise `PJ_SPIKE_CLAUDE_LONG_SECS` to
make `[claude-long]` run longer.

On token refresh: `~/.claude/sandbox-oauth-token` is a long-lived
`claude setup-token` token with no refresh token, so `[claude-long]` can only
show that a long session keeps working through the proxy. If Claude's OAuth
refresh path needs testing for real, the finding should say so and how.

## Results

Run on 2026-10-06: macOS 26.6.2 (25G83), Lima 2.2.0 (vz, Ubuntu 26.04 guest),
mitmproxy 12.2.3 (Python 3.14.3, installed with `uv tool install mitmproxy`),
`--repo whiskerlabs/fire` (private).

| Check         | Command                                  | Result (OK / FAIL) | Error text, if FAIL | Brokered or unbrokered |
|---------------|------------------------------------------|--------------------|---------------------|------------------------|
| `claude`      | `claude -p 'say ok'`                     | OK                 |                     | brokered               |
| `claude-long` | a multi-turn `claude -p` run (4 × `sleep 30` via Bash, ~2.5 min) | OK |           | brokered               |
| `copilot`     | `copilot -p 'say ok'`                    | OK                 |                     | brokered               |
| `gh`          | `gh api user`                            | OK                 |                     | brokered               |
| `git`         | `git ls-remote https://github.com/whiskerlabs/fire` | OK      |                     | brokered               |

For each FAIL, also note whether the mitmdump log shows the request arriving.
If it arrived, the CA was trusted and the token was refused. If it didn't, the
CA was rejected or the certificate is pinned.

## Findings

**Every agent can be brokered. None is marked unbrokered**, so no profile gets
`unbrokered: true`.

- All five checks passed with only placeholders in the guest. The mitmdump
  log shows the placeholder rewritten for `api.anthropic.com` (claude),
  `api.github.com` (gh, copilot), `api.business.githubcopilot.com` (copilot)
  and `github.com` (git). Every request reached the proxy and was
  intercepted, so none of these tools pins certificates; each trusted the CA
  through the system store plus `NODE_EXTRA_CA_CERTS`/`SSL_CERT_FILE`.
- No "placeholder sent to a non-target host" lines appeared. Hosts reached
  without credentials: `http-intake.logs.us5.datadoghq.com` (Claude
  telemetry), `cafe.github.com` and `telemetry.business.githubcopilot.com`
  (Copilot telemetry). Some `api.anthropic.com` calls (`mcp-registry`,
  `directory/plugins`) carry no auth at all.
- `git` sends an unauthenticated request first, gets a 401, then retries via
  the credential helper; the retry is the one rewritten. Normal git behaviour.
- `GET api.anthropic.com/api/claude_cli/bootstrap` returned 403 twice with the
  rewritten setup-token. Claude still worked; this looks like a scope limit of
  `claude setup-token` tokens rather than a proxy problem, but it wasn't
  compared against a direct, unproxied run.
- **Profile gap:** Copilot on a Business plan talks to
  `api.business.githubcopilot.com`. The spike matched `.githubcopilot.com`, but
  `profiles/copilot/inject.json` only lists `api.githubcopilot.com` and
  `api.individual.githubcopilot.com`, so the real proxy wouldn't inject there.
  The allowlist (`*.githubcopilot.com`) already covers it.
- Token refresh wasn't exercised: the token is a long-lived setup token with
  no refresh token. `claude-long` only shows a multi-minute session keeps
  working through the proxy.
- Host setup: the Homebrew **cask** `mitmproxy` is an unnotarized Developer ID
  app; once quarantined, Gatekeeper SIGKILLs `mitmdump` on launch (exit 137,
  empty log). Installing from PyPI (`uv tool install mitmproxy`) avoids it.
- `update-ca-certificates` prints `rehash: warning: skipping
  ca-certificates.crt ...`; that's the stock Ubuntu bundle file and harmless.
