#!/usr/bin/env python3
"""Coverage gate for MEditor CI.

Parses an lcov file (produced by llvm-cov export after llvm-profdata merge),
computes line coverage for Sources/MEditor, dedupes files compiled into more
than one binary, and fails the build if coverage drops below thresholds.

Usage:
    python3 scripts/coverage_gate.py coverage.lcov [--overall-min 15] [--logic-min 40]
        [--min-dir DIR=PERCENT] ...

Thresholds (defaults match the repo baseline with headroom):
    overall : whole Sources/MEditor  (floor 15%)
    logic   : non-View code          (floor 40%)

Per-path floors are optional and repeatable: ``--min-dir Services=50``. DIR is a
path prefix relative to --source-root, so both a whole layer (``Services``) and a
subtree (``Services/AI/Agent``) can be ratcheted. ``DIR/`` must exist in the
coverage data — a floor with no matching files fails the gate, since that usually
means a rename/typo rather than an intentionally empty directory.
"""
import argparse
import collections
import sys

def parse_lcov(path):
    """Return {abs_path: (lines_found, lines_hit)}."""
    records = {}
    current = None
    lf = lh = 0
    for raw in open(path, errors="replace"):
        line = raw.strip()
        if line.startswith("SF:"):
            current = line[3:]
            lf = lh = 0
        elif line.startswith("LF:"):
            lf = int(line[3:])
        elif line.startswith("LH:"):
            lh = int(line[3:])
        elif line == "end_of_record" and current:
            records[current] = (lf, lh)
            current = None
    return records

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lcov", help="path to lcov file")
    ap.add_argument("--overall-min", type=float, default=15.0)
    ap.add_argument("--logic-min", type=float, default=40.0)
    ap.add_argument("--source-root", default="Sources/MEditor")
    ap.add_argument(
        "--min-dir",
        action="append",
        default=[],
        metavar="DIR=PERCENT",
        help="path-prefix floor relative to --source-root; repeatable",
    )
    args = ap.parse_args()

    dir_floors = {}
    for spec in args.min_dir:
        name, sep, value = spec.rpartition("=")
        if not sep or not name:
            ap.error("--min-dir 需要 DIR=PERCENT 形式，收到: %r" % spec)
        try:
            dir_floors[name] = float(value)
        except ValueError:
            ap.error("--min-dir 的百分比不是数字: %r" % spec)

    records = parse_lcov(args.lcov)
    # Keep only app sources; dedupe by path relative to the source root
    # (a file compiled into both the app and the test bundle appears twice).
    by_key = {}
    for path, (lf, lh) in records.items():
        marker = "/" + args.source_root + "/"
        if marker not in path:
            continue
        key = path.split(marker, 1)[1]
        cur = by_key.get(key)
        # Same file can appear several times (multi-binary build). Keep the
        # record with the largest LF and use THAT record's own LH: found/hit
        # must come from the same measurement, so never max() them separately.
        if cur is None or lf > cur[0]:
            by_key[key] = (lf, lh)

    if not by_key:
        print("ERROR: no coverage data for " + args.source_root)
        sys.exit(1)

    def stats(pred):
        """Return (lines_found, lines_hit) over the files matching pred.

        顺序是 (found, hit)——调用方解包时别搞反，反了会让百分比变成倒数的量级
        且门槛判定整体失效（方向相反）。
        """
        tot = hit = 0
        for key, (lf, lh) in by_key.items():
            if not pred(key):
                continue
            tot += lf
            hit += lh
        return tot, hit

    def coverage_for(prefix):
        """Coverage of every file under a path prefix (``Services`` / ``Services/AI/Agent``)."""
        pref = prefix if prefix.endswith("/") else prefix + "/"
        return stats(lambda k: k.startswith(pref))

    ov_tot, ov_hit = stats(lambda k: True)
    lg_tot, lg_hit = stats(lambda k: not k.startswith("Views/"))
    ov_pct = ov_hit / ov_tot * 100 if ov_tot else 0.0
    lg_pct = lg_hit / lg_tot * 100 if lg_tot else 0.0

    print("Sources/MEditor files with coverage data: %d" % len(by_key))
    print("  overall : %6d/%6d lines = %5.1f%%  (floor %.0f%%)" % (ov_hit, ov_tot, ov_pct, args.overall_min))
    print("  logic   : %6d/%6d lines = %5.1f%%  (floor %.0f%%)" % (lg_hit, lg_tot, lg_pct, args.logic_min))

    dirs = collections.defaultdict(lambda: [0, 0])
    for key, (lf, lh) in by_key.items():
        d = key.split("/", 1)[0] if "/" in key else "(root)"
        dirs[d][0] += lf
        dirs[d][1] += lh
    print("")
    print("per-directory:")
    for d, (lf, lh) in sorted(dirs.items(), key=lambda x: -x[1][0]):
        pct = lh / lf * 100 if lf else 0.0
        floor = dir_floors.get(d)
        suffix = "  (floor %.0f%%)" % floor if floor is not None else ""
        print("  %-24s %6d/%6d  %5.1f%%%s" % (d, lh, lf, pct, suffix))

    # Path floors are matched by prefix (not just the top-level directory), so a
    # subtree like Services/AI/Agent can be ratcheted independently.
    floor_rows = []
    for d, floor in sorted(dir_floors.items()):
        tot, hit = coverage_for(d)
        floor_rows.append((d, floor, hit, tot))
    if floor_rows:
        print("")
        print("path floors:")
        for d, floor, hit, tot in floor_rows:
            pct = hit / tot * 100 if tot else 0.0
            status = "ok" if tot and pct >= floor else "FAIL"
            print("  %-28s %6d/%6d  %5.1f%%  (floor %.0f%%)  %s"
                  % (d, hit, tot, pct, floor, status))

    failed = []
    if ov_pct < args.overall_min:
        failed.append("overall %.1f%% < %.0f%%" % (ov_pct, args.overall_min))
    if lg_pct < args.logic_min:
        failed.append("logic (non-view) %.1f%% < %.0f%%" % (lg_pct, args.logic_min))
    for d, floor, _hit, tot in floor_rows:
        if tot == 0:
            failed.append("path %s: no coverage data (floor %.0f%%)" % (d, floor))
            continue
        pct = _hit / tot * 100
        if pct < floor:
            failed.append("path %s %.1f%% < %.0f%%" % (d, pct, floor))
    if failed:
        print("")
        print("COVERAGE GATE FAILED: " + ", ".join(failed))
        sys.exit(1)
    print("")
    print("Coverage gate passed.")

if __name__ == "__main__":
    main()
