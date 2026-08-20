# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
"""
Standalone diagnostic for the per-suite coverage data files written by
run-python-coverage.sh. Opens each `python-coverage.<suite>` (bare file
written by pytest-cov's end-of-session combine) and any matching
`python-coverage.<suite>.<host>.<pid>.<rand>` parallel fragments, then
prints what coverage actually recorded:

  * total measured files (file table from CoverageData)
  * how many of those have at least one executed line
  * the breakdown by package bucket
  * the top 5 files by lines covered (sanity check that real work was
    measured, not just module-import-time top-level code)

Run inside the container after a coverage run:

    python /rocopt-release/scripts/lib/inspect-python-coverage.py \
        /rocopt-release/test-results

Or via run-python-coverage.sh after the test phase by passing the
results dir on argv; defaults to ${RESULTS_DIR:-./test-results}.

This intentionally uses CoverageData (not Coverage.report / .load) so we
inspect the on-disk state without re-arming the tracer, side-effects on
the data file, or rcfile-driven path canonicalisation. What you see here
is exactly what is in the SQLite blob.
"""
import glob
import os
import sys
from collections import defaultdict

from coverage.sqldata import CoverageData


SUITES = [
    "python-coverage.cuopt",
    "python-coverage.cuopt_server",
    "python-coverage.cuopt_sh_client",
    "python-coverage.cuopt_service",
]


def classify(path: str) -> str:
    if "python-coverage-shim" in path:
        return "sitecustomize"
    if "/cuopt_sh_client/" in path or path.endswith("cuopt_sh_client"):
        return "cuopt_sh_client"
    if "/cuopt_server/" in path or "/python/cuopt_server/" in path:
        return "cuopt_server"
    if "/cuopt/cuopt/" in path or "/python/cuopt/" in path:
        return "cuopt"
    return "other"


def fragments_for(base: str) -> list[str]:
    """Bare file + any parallel-suffixed siblings (same convention as
    run-python-coverage.sh's combine step)."""
    fragments = []
    if os.path.isfile(base):
        fragments.append(base)
    fragments.extend(sorted(glob.glob(base + ".*")))
    return fragments


def inspect_one(base: str) -> None:
    print(f"\n========== {os.path.basename(base)} ==========")
    frags = fragments_for(base)
    print(f"on-disk files: {len(frags)}")
    for f in frags:
        size = os.path.getsize(f) if os.path.isfile(f) else 0
        print(f"  {os.path.basename(f)}  ({size} bytes)")
    if not frags:
        print("(no data on disk for this suite)")
        return

    # Merge all fragments in-memory so we get a single view per suite,
    # but DON'T touch the on-disk fragments (no_disk=True on the
    # aggregator). We close each piece explicitly because coverage 7.x's
    # CoverageData opens SQLite with `cache=shared` URIs that collide
    # when multiple instances are alive in the same interpreter (failure
    # mode: "database other_db is already in use" on the 2nd read in a
    # batch).
    merged = CoverageData(basename=base + ".__inspect__", no_disk=True)
    for f in frags:
        piece = None
        try:
            piece = CoverageData(basename=f)
            piece.read()
            merged.update(piece)
        except Exception as e:
            print(f"  WARN: cannot read {os.path.basename(f)}: {e}")
        finally:
            # Release the SQLite handles on this piece so the next
            # iteration's CoverageData() doesn't collide on the shared
            # `cache=shared` in-memory URI. We MUST NOT call erase() --
            # that would delete the data file from disk. We just want to
            # close the connection.
            if piece is not None:
                # CoverageData -> SqliteDb stored on piece._dbs (one per
                # thread). Close each db connection directly; this is
                # private API but it's the only knob coverage exposes for
                # closing without deletion.
                dbs = getattr(piece, "_dbs", None)
                if isinstance(dbs, dict):
                    for db in list(dbs.values()):
                        close_fn = getattr(db, "close", None)
                        if callable(close_fn):
                            try:
                                close_fn()
                            except Exception:
                                pass
                    dbs.clear()

    files = sorted(merged.measured_files())
    print(f"measured files (file table rows): {len(files)}")

    # Critical distinction: a file appears in the data even when pytest-cov
    # collected it from `--cov=PKG` but coverage never recorded a line.
    # Split them so we can see which case we're in.
    files_with_lines: list[tuple[str, int]] = []
    files_zero_lines: list[str] = []
    for f in files:
        lines = merged.lines(f)
        if lines:
            files_with_lines.append((f, len(lines)))
        else:
            files_zero_lines.append(f)

    print(f"  with >= 1 executed line: {len(files_with_lines)}")
    print(f"  with 0 executed lines:   {len(files_zero_lines)}")

    bucket_counts = defaultdict(lambda: [0, 0])
    for f, n in files_with_lines:
        bucket_counts[classify(f)][0] += 1
    for f in files_zero_lines:
        bucket_counts[classify(f)][1] += 1
    print("by bucket   (with-lines / zero-lines):")
    for b in ("cuopt", "cuopt_server", "cuopt_sh_client", "sitecustomize", "other"):
        wl, zl = bucket_counts.get(b, (0, 0))
        print(f"  {b:>15s}: {wl:>4d} / {zl:>4d}")

    if files_with_lines:
        print("top 5 files by executed-line count:")
        for f, n in sorted(files_with_lines, key=lambda kv: -kv[1])[:5]:
            print(f"  {n:>5d}  {f}")

    if files_zero_lines:
        print("first 5 zero-line files (likely pytest-cov source list but tracer never fired):")
        for f in files_zero_lines[:5]:
            print(f"         {f}")


def main():
    results_dir = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.environ.get("RESULTS_DIR", "./test-results")
    )
    results_dir = os.path.abspath(results_dir)
    print(f"Inspecting coverage data files under: {results_dir}")
    if not os.path.isdir(results_dir):
        sys.exit(f"results dir not found: {results_dir}")

    for suite in SUITES:
        inspect_one(os.path.join(results_dir, suite))


if __name__ == "__main__":
    main()
