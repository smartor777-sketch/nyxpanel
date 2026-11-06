#!/usr/bin/env python3
"""Fail if tracked files contain strings from the local secrets list.

Real hostnames, public IPs and account names must never be committed to this
repository: the published history is sanitised and must stay that way. The
list of forbidden strings lives *outside* git, in ``local/sanitise-blacklist.txt``
(one literal per line, ``#`` starts a comment). Only the names of the patterns
are printed, never the secrets themselves.

Usage:
    python ops/check_no_secrets.py [--list PATH] [--quiet]

Environment:
    NYX_SECRETS_LIST   default list path, overrides the built-in default

Exit codes:
    0  clean, or no list configured
    1  forbidden string found in a tracked file
    2  bad usage / not a git repository
"""

import argparse
import os
import subprocess
import sys

DEFAULT_LISTS = (
    "local/sanitise-blacklist.txt",
    ".git/info/sanitise-blacklist.txt",
)
MAX_BYTES = 4 * 1024 * 1024
MAX_REPORT_PER_FILE = 5


def repo_root() -> str:
    p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True)
    if p.returncode != 0:
        sys.exit(2)
    return p.stdout.decode("utf-8", "replace").strip()


def tracked_files(root: str):
    p = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    if p.returncode != 0:
        sys.exit(2)
    for raw in p.stdout.split(b"\0"):
        if raw:
            yield raw.decode("utf-8", "surrogateescape")


def load_patterns(path: str):
    patterns = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if len(s) < 4:
                # Too short: would match half the codebase and teach nothing.
                print(f"warning: ignoring too-short pattern at {path}: {s!r}",
                      file=sys.stderr)
                continue
            patterns.append(s)
    return patterns


def is_binary(data: bytes) -> bool:
    return b"\0" in data[:8192]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", dest="list_path", default=None,
                    help="path to the secrets list")
    ap.add_argument("--quiet", action="store_true",
                    help="print nothing when clean")
    args = ap.parse_args()

    root = repo_root()
    candidates = []
    if args.list_path:
        candidates.append(os.path.join(root, args.list_path))
    env_path = os.environ.get("NYX_SECRETS_LIST")
    if env_path:
        candidates.append(env_path if os.path.isabs(env_path)
                          else os.path.join(root, env_path))
    candidates.extend(os.path.join(root, p) for p in DEFAULT_LISTS)

    list_path = next((p for p in candidates if os.path.isfile(p)), None)
    if not list_path:
        if not args.quiet:
            print("no secrets list found; nothing to check "
                  f"(looked for: {', '.join(DEFAULT_LISTS)})")
        return 0

    patterns = load_patterns(list_path)
    if not patterns:
        if not args.quiet:
            print(f"secrets list is empty: {list_path}")
        return 0

    hits = 0
    scanned = 0
    for rel in tracked_files(root):
        full = os.path.join(root, rel)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        try:
            if os.path.getsize(full) > MAX_BYTES:
                continue
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if is_binary(data):
            continue
        scanned += 1
        text = data.decode("utf-8", "replace")
        lowered = text.lower()
        reported = 0
        for idx, pattern in enumerate(patterns, 1):
            if pattern.lower() not in lowered:
                continue
            hits += 1
            for lineno, line in enumerate(text.splitlines(), 1):
                if pattern.lower() in line.lower():
                    print(f"{rel}:{lineno}: pattern #{idx}")
                    reported += 1
                    if reported >= MAX_REPORT_PER_FILE:
                        print(f"{rel}: ... more matches suppressed")
                        break
            if reported >= MAX_REPORT_PER_FILE:
                break

    if hits:
        print(f"\n{hits} forbidden pattern match(es) in tracked files. "
              "Replace them with placeholders before committing.",
              file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"ok: {scanned} tracked text files checked, no matches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
