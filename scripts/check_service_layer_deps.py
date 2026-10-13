#!/usr/bin/env python3
"""Service-layer dependency-direction guard (P0-10).

``Sources/MEditor/Services/**`` sits *below* ``ViewModels/`` in this app's
layering: services are driven by the view model, never the other way round.
The view-model type is ``AppState``. A service that names ``AppState`` acquires
a reverse dependency on the view layer, which costs two things:

* "what a service may ask of the app" stops having a boundary -- every new call
  site silently widens the coupling, and it is only ever noticed in review;
* the service can only be unit-tested against a whole ``AppState``. The code
  used to dodge that by passing ``nil`` in tests, which swallows every feedback
  branch silently -- those paths were neither asserted nor reviewable.

Host capabilities must travel through an explicit port instead. For the
background-agent services that port is ``AgentHostPort``.

Two lists drive this check:

``FORBIDDEN``
    Files that were moved onto a port and must stay there. This is a ratchet:
    it only ever grows. "The file no longer mentions AppState" is not a reason
    to delist it -- that is exactly what makes the entry work.

``KNOWN_HOST_AWARE``
    Services that legitimately still name ``AppState``, each with the reason.
    A Services file that mentions ``AppState`` while appearing in *neither* list
    fails the check: a new reverse dependency must be a conscious decision
    (route it through a port, or register it here with a reason).

Comments are stripped before matching, so prose about the port is fine; only
real code counts. Known limitation: raw string literals (``#"..."#``) are not
handled, which can only ever produce a false *positive*.
Usage:
    python3 scripts/check_service_layer_deps.py [--root .] [--quiet]
"""
import argparse
import os
import re
import sys

SERVICES_DIR = "Sources/MEditor/Services"
HOST_TYPE = "AppState"
HOST_TYPE_RE = re.compile(r"\b" + HOST_TYPE + r"\b")

# Files that must NOT name the view-model type. Grows only.
FORBIDDEN = {
    "Sources/MEditor/Services/AI/Agent/BackgroundAgentTaskService.swift":
        "host capabilities must go through AgentHostPort (P0-10)",
    "Sources/MEditor/Services/AI/Agent/AgentSchedulerService.swift":
        "host capabilities must go through AgentHostPort (P0-10)",
}

# Services that legitimately name the view-model type, with the reason.
KNOWN_HOST_AWARE = {
    "Sources/MEditor/Services/AI/Agent/AgentHostPort.swift":
        "the port itself + AppState's conformance (the wiring point by design)",
    "Sources/MEditor/Services/AI/Agent/AgentDocumentAdapter.swift":
        "adapter between AppState and the tool layer -- this *is* the port",
    "Sources/MEditor/Services/AI/Agent/AgentContext.swift":
        "composition root: AgentContext.make(appState:checkpoint:)",
    "Sources/MEditor/Services/AI/AIChatCoordinator.swift":
        "presenter: grounding reads tab / selection / theme / user skills",
    "Sources/MEditor/Services/AI/InlineEditSession.swift":
        "presenter: drives DiffReviewState for the inline-edit bar",
    "Sources/MEditor/Services/AI/SlashCommands/SlashAICommandExecutor.swift":
        "presenter: drives DiffReviewState for slash commands",
    "Sources/MEditor/Services/AI/AgentDemoFlow.swift":
        "demo flow: opens workspace / files, toggles the assistant pane",
}


def strip_comments(src):
    """Return *src* with Swift comments removed, string literals kept.

    Handles ``//``, nested ``/* */``, and skips over string literals (both the
    single-quoted and the triple-quoted kind) so a ``//`` inside a string does
    not start a comment. Newlines outside strings are preserved so line numbers
    stay meaningful.
    """
    out = []
    i, n = 0, len(src)
    in_line = False
    depth = 0
    quote = None  # None, or the opening delimiter of the string we are inside
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            i += 1
            continue
        if depth:
            if c == "*" and nxt == "/":
                depth -= 1
                i += 2
            elif c == "/" and nxt == "*":
                depth += 1
                i += 2
            else:
                if c == "\n":
                    out.append(c)
                i += 1
            continue
        if quote:
            if c == "\\":
                out.append(c)
                if nxt:
                    out.append(nxt)
                i += 2
                continue
            if quote == '"""':
                if src.startswith('"""', i):
                    quote = None
                    out.append('"""')
                    i += 3
                    continue
            elif c == '"':
                quote = None
            out.append(c)
            i += 1
            continue
        if src.startswith('"""', i):
            quote = '"""'
            out.append('"""')
            i += 3
            continue
        if c == '"':
            quote = '"'
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            depth = 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def swift_files(root):
    """Relative posix paths of every .swift file under Services/."""
    base = os.path.join(root, SERVICES_DIR)
    found = []
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                found.append(os.path.relpath(full, root).replace(os.sep, "/"))
    return sorted(found)


def line_numbers(src, pattern):
    """1-based line numbers in *src* matching *pattern*."""
    return [n for n, line in enumerate(src.splitlines(), 1) if pattern.search(line)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--quiet", action="store_true",
                    help="only print problems")
    args = ap.parse_args()

    root = args.root
    if not os.path.isdir(os.path.join(root, SERVICES_DIR)):
        print(f"::error:: {SERVICES_DIR} not found under {root}")
        return 1

    mentions = {}
    for rel in swift_files(root):
        with open(os.path.join(root, rel), errors="replace") as fh:
            src = strip_comments(fh.read())
        hits = line_numbers(src, HOST_TYPE_RE)
        if hits:
            mentions[rel] = hits

    failures = []

    # 1. Ratchet: files that moved onto a port must stay clean.
    for rel, reason in sorted(FORBIDDEN.items()):
        if rel in mentions:
            failures.append(
                f"{rel}: names {HOST_TYPE} at line(s) "
                f"{', '.join(map(str, mentions[rel]))} -- {reason}")

    # 2. New reverse dependencies must be registered on purpose.
    for rel, hits in sorted(mentions.items()):
        if rel in FORBIDDEN or rel in KNOWN_HOST_AWARE:
            continue
        failures.append(
            f"{rel}: new reverse dependency on {HOST_TYPE} "
            f"(line(s) {', '.join(map(str, hits))}) -- route it through a port, "
            f"or register it in KNOWN_HOST_AWARE with a reason")

    if not args.quiet:
        print(f"service-layer guard: {len(mentions)}/{len(swift_files(root))} "
              f"Services file(s) name {HOST_TYPE}")
        print(f"  forbidden (must stay clean): {len(FORBIDDEN)}")
        for rel, reason in sorted(FORBIDDEN.items()):
            state = "VIOLATION" if rel in mentions else "clean"
            print(f"    [{state}] {rel} -- {reason}")
        print(f"  registered host-aware: {len(KNOWN_HOST_AWARE)}")
        for rel, reason in sorted(KNOWN_HOST_AWARE.items()):
            state = f"line(s) {', '.join(map(str, mentions[rel]))}" if rel in mentions \
                else "no longer mentions it -- consider moving to FORBIDDEN"
            print(f"    {rel} [{state}] -- {reason}")

    if failures:
        print()
        for f in failures:
            print(f"::error:: {f}")
        print(f"\nFAILED: {len(failures)} service-layer dependency problem(s)")
        return 1

    if not args.quiet:
        print("\nOK: no service-layer dependency-direction problems")
    return 0


if __name__ == "__main__":
    sys.exit(main())
