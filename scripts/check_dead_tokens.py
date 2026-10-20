#!/usr/bin/env python3
"""Dead design-token guard.

``DesignTokens.swift`` is the design system's single source of truth. A token
that nothing references is not a harmless spare -- it actively misleads:

* it looks like the sanctioned value for its purpose, so the next person
  reaches for it and silently diverges from what the UI actually does
  (``DS.Color.rowSelected`` was ``appAccent.opacity(0.13)`` while every real
  row used ``0.16`` / ``0.12``);
* or it is the relic of an abandoned feature, and its presence implies a
  capability that does not exist (``DS.Shadow`` was a half-built elevation
  system: ``card()`` returned a colour while the radius and offset lived in
  separate loose constants, so no caller could ever apply it as a unit).

Deleting is the fix; this guard keeps it deleted.

Scale ladders are the one exception and are listed in ``ALLOW_UNUSED``: a
radius ladder is a *menu*, and an unused step is a menu item nobody ordered
yet, not rot. Everything else must have at least one reference.

Like ``check_service_layer_deps.py`` this is a ratchet: an allow-listed token
that has since been adopted fails the check, so the allowance gets cleaned up
instead of quietly becoming permanent.

Usage:
    python3 scripts/check_dead_tokens.py [--root .] [--quiet]
"""
import argparse
import os
import re
import sys

TOKENS_FILE = "Sources/MEditor/Views/Shared/DesignTokens.swift"
SCAN_DIR = "Sources/MEditor"
NAMESPACE_RE = re.compile(r"^    enum (\w+) \{")
MEMBER_RE = re.compile(r"^        static (?:let|var|func) (\w+)")

# Tokens allowed to be unreferenced, with the reason.
ALLOW_UNUSED = {
    "Radius.lg": "radius ladder is a menu; unused step is not rot",
    "Radius.full": "radius ladder is a menu; unused step is not rot",
}


def swift_sources(root):
    """Relative posix paths of every .swift file we should count references in."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(root, SCAN_DIR)):
        for name in filenames:
            if name.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if rel != TOKENS_FILE:
                    found.append(rel)
    return sorted(found)


def parse_tokens(root):
    """[(namespace, member)] declared inside DS, in source order."""
    tokens = []
    namespace = None
    with open(os.path.join(root, TOKENS_FILE), errors="replace") as fh:
        for line in fh:
            ns = NAMESPACE_RE.match(line)
            if ns:
                namespace = ns.group(1)
                continue
            member = MEMBER_RE.match(line)
            if member and namespace:
                tokens.append((namespace, member.group(1)))
    return tokens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    root = args.root
    if not os.path.isfile(os.path.join(root, TOKENS_FILE)):
        print(f"::error:: {TOKENS_FILE} not found under {root}")
        return 1

    tokens = parse_tokens(root)
    if not tokens:
        print(f"::error:: no DS tokens parsed out of {TOKENS_FILE} -- "
              f"the parser is stale, not the file empty")
        return 1

    corpus = []
    for rel in swift_sources(root):
        with open(os.path.join(root, rel), errors="replace") as fh:
            corpus.append(fh.read())
    corpus = "\n".join(corpus)

    unused, adopted = [], []
    for ns, member in tokens:
        key = f"{ns}.{member}"
        referenced = f"DS.{ns}.{member}" in corpus
        if not referenced:
            unused.append(key)
        elif key in ALLOW_UNUSED:
            adopted.append(key)

    failures = []
    for key in unused:
        if key not in ALLOW_UNUSED:
            failures.append(
                f"{key}: declared in DS but referenced nowhere -- delete it, or "
                f"register it in ALLOW_UNUSED with a reason")
    for key in adopted:
        failures.append(
            f"{key}: now referenced -- drop it from ALLOW_UNUSED "
            f"(the ratchet only tightens)")

    if not args.quiet:
        print(f"dead-token guard: {len(tokens)} DS token(s) parsed, "
              f"{len(unused)} unreferenced")
        for key in unused:
            mark = "allowed" if key in ALLOW_UNUSED else "DEAD"
            reason = f" -- {ALLOW_UNUSED[key]}" if key in ALLOW_UNUSED else ""
            print(f"  [{mark}] {key}{reason}")
        for key in adopted:
            print(f"  [adopted] {key} -- remove from ALLOW_UNUSED")

    if failures:
        print()
        for f in failures:
            print(f"::error:: {f}")
        print(f"\nFAILED: {len(failures)} dead design token(s)")
        return 1

    if not args.quiet:
        print("\nOK: no dead design tokens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
