"""Looks for real tokens without ever holding one, for `pj-sandbox verify`.

The host runs `python3 verify_scan.py fingerprint SALT` with a token on
stdin and gets back its fingerprint: the first 16 hex of
sha256(SALT + one 12-character window from the token's middle). Only that,
with a per-run random SALT, goes to the guest. One window, not every sliding
window: overlapping windows' hashes chain, so cracking one would give the
next a character at a time. A token shorter than the window prints nothing.

The guest runs the same file, sent over ssh stdin as `python3 -c`, as
`scan SALT LABEL=FP... -- PATH...`. It hashes every 12-byte window of each
PATH (directories walked, symlinks and .git/objects skipped, files over
SCAN_LIMIT bytes skipped) and of its own stdin, the session's `env`, and
prints `hit<TAB>LABEL<TAB>PATH` for each fingerprint found, then
`scanned<TAB>COUNT`. A path that's missing or unreadable is skipped.
"""

import hashlib
import os
import sys

WINDOW = 12
FP_HEX = 16
SCAN_LIMIT = 4 * 1024 * 1024


def fingerprint(salt, token):
    if len(token) < WINDOW:
        return ""
    start = (len(token) - WINDOW) // 2
    window = token[start:start + WINDOW].encode()
    return hashlib.sha256(salt.encode() + window).hexdigest()[:FP_HEX]


def hits(salt, wanted, data):
    """The labels in WANTED (fingerprint -> label) whose window is in DATA."""
    base = hashlib.sha256(salt.encode())
    found = set()
    for i in range(len(data) - WINDOW + 1):
        h = base.copy()
        h.update(data[i:i + WINDOW])
        label = wanted.get(h.hexdigest()[:FP_HEX])
        if label is not None:
            found.add(label)
    return found


def _files(path):
    if os.path.islink(path):
        return
    if os.path.isfile(path):
        yield path
        return
    for top, dirs, names in os.walk(path):
        if os.path.basename(top) == ".git":
            dirs[:] = [d for d in dirs if d != "objects"]
        for name in names:
            full = os.path.join(top, name)
            if not os.path.islink(full):
                yield full


def _read(path):
    try:
        if os.path.getsize(path) > SCAN_LIMIT:
            return None
        with open(path, "rb") as f:
            return f.read(SCAN_LIMIT + 1)
    except OSError:
        return None


def scan(salt, wanted, paths, stdin, out):
    count = 0
    for label in sorted(hits(salt, wanted, stdin)):
        out.write("hit\t%s\tenv\n" % label)
    for path in paths:
        for f in _files(path):
            data = _read(f)
            if data is None:
                continue
            count += 1
            for label in sorted(hits(salt, wanted, data)):
                out.write("hit\t%s\t%s\n" % (label, f))
    out.write("scanned\t%d\n" % count)


def main(argv):
    if len(argv) == 3 and argv[1] == "fingerprint":
        print(fingerprint(argv[2], sys.stdin.read().strip()))
        return 0
    if len(argv) >= 3 and argv[1] == "scan" and "--" in argv:
        sep = argv.index("--")
        wanted = {}
        for pair in argv[3:sep]:
            label, _, fp = pair.partition("=")
            wanted[fp] = label
        scan(argv[2], wanted, argv[sep + 1:], sys.stdin.buffer.read(), sys.stdout)
        return 0
    sys.stderr.write("usage: verify_scan.py fingerprint SALT | scan SALT LABEL=FP... -- PATH...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
