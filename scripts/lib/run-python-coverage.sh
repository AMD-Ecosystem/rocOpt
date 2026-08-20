#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Phase D (Python side): coverage.py-based Python coverage for the three
# rocopt Python test suites (cuopt, cuopt_server, cuopt_self_hosted) -- the
# mirror of run-cpp-coverage.sh.
#
# 1. Verifies coverage / pytest-cov are installed in the active conda env;
#    installs them only if missing.
# 2. Delegates the actual test run to scripts/lib/in-container-tests.sh
#    --python, which already knows how to:
#       - run ci/run_cuopt_pytests.sh        (cuopt library)
#       - run ci/run_cuopt_server_pytests.sh with ROCM_HOME=/opt/rocm
#         (cuopt_server)
#       - start cuopt_service on port 5050, wait for /cuopt/health, run
#         pytest under python/cuopt_self_hosted/tests, then SIGTERM the
#         server (cuopt_self_hosted).
#    We toggle coverage on by exporting PYTHON_COVERAGE=1 and
#    COVERAGE_FILE=... before invoking that script; the runner appends
#    `--cov=<pkg> --cov-append` to each pytest invocation so the three
#    suites accumulate into one .coverage data file.
# 3. Generates terminal / HTML / JSON coverage reports under RESULTS_DIR and
#    writes the platform-coverage JSON to ${ARTIFACTS_FOLDER:-/artifacts}
#    matching the C++ artifact path.
#
# Usage (inside rocopt-tester:local):
#   bash /rocopt-release/scripts/lib/run-python-coverage.sh [--skip-datasets]

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${_SCRIPT_DIR}/common.sh"

ROCOPT_DIR="${ROCOPT_DIR:-/rocopt-release}"
RESULTS_DIR="${RESULTS_DIR:-${ROCOPT_DIR}/test-results}"

# Coverage data + report destinations.
#
# Architecture: each pytest suite writes to its OWN COVERAGE_FILE so that
# pytest-cov's internal combining_cov.combine() -- which greedily globs
# `<data_file>.*` and DELETES every match -- cannot consume fragments from
# a sibling suite or from the long-running cuopt_service subprocess
# workers. The cuopt_service subprocess (instrumented via
# COVERAGE_PROCESS_START) writes to a fourth, separate COVERAGE_FILE for
# the same reason. After the test phase, we do ONE explicit `coverage
# combine` over the four basename globs to merge everything into the
# canonical data file the reports are generated from.
#
# Anything else that tries to share state across these via a single
# COVERAGE_FILE will lose data; see commit history for the failure mode
# (final report saw only `sitecustomize.py`, 1 fragment file at end of
# run despite three suites running to completion).
COVERAGE_DATA_FILE="${RESULTS_DIR}/python-coverage.coverage"
COVERAGE_DATA_FILE_CUOPT="${RESULTS_DIR}/python-coverage.cuopt"
COVERAGE_DATA_FILE_CUOPT_SERVER="${RESULTS_DIR}/python-coverage.cuopt_server"
COVERAGE_DATA_FILE_CUOPT_SH_CLIENT="${RESULTS_DIR}/python-coverage.cuopt_sh_client"
COVERAGE_DATA_FILE_CUOPT_SERVICE="${RESULTS_DIR}/python-coverage.cuopt_service"
PER_SUITE_DATA_FILES=(
    "${COVERAGE_DATA_FILE_CUOPT}"
    "${COVERAGE_DATA_FILE_CUOPT_SERVER}"
    "${COVERAGE_DATA_FILE_CUOPT_SH_CLIENT}"
    "${COVERAGE_DATA_FILE_CUOPT_SERVICE}"
)
REPORT_TXT="${RESULTS_DIR}/python-coverage-report.txt"
REPORT_HTML="${RESULTS_DIR}/python-coverage-html"
REPORT_JSON="${RESULTS_DIR}/python-coverage.json"
REPORT_XML="${RESULTS_DIR}/python-coverage.xml"

# .coveragerc lookup: same precedence the in-container runner uses, so the
# user only needs to set it in one place. ROCm fork keeps a copy at the repo
# root; upstream cuopt also has one under python/cuopt/.coveragerc.
COVERAGE_CONFIG="${PYTHON_COVERAGE_CONFIG:-}"
if [ -z "${COVERAGE_CONFIG}" ]; then
    for candidate in \
        "${ROCOPT_DIR}/.coveragerc" \
        "${ROCOPT_DIR}/python/cuopt/.coveragerc" \
        "${ROCOPT_DIR}/python/.coveragerc"
    do
        if [ -f "${candidate}" ]; then
            COVERAGE_CONFIG="${candidate}"
            break
        fi
    done
fi

# Default suite selection: all three. Callers can narrow with the same flags
# in-container-tests.sh accepts (we forward them).
SKIP_DATASETS=0
FORWARDED_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --skip-datasets) SKIP_DATASETS=1; FORWARDED_ARGS+=("${arg}") ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--skip-datasets]

Runs the three Python test suites (cuopt, cuopt_server, cuopt_self_hosted)
under coverage.py and emits terminal / HTML / JSON coverage reports under
\${RESULTS_DIR:-${ROCOPT_DIR}/test-results}.

The actual test invocation is delegated to scripts/lib/in-container-tests.sh
--python, which handles the per-suite constraints (ROCM_HOME=/opt/rocm for
cuopt_server, server startup on :5050 for cuopt_self_hosted).
EOF
            exit 0
            ;;
        *)
            # Forward unknown args verbatim to the test runner -- this lets
            # the user pass --ctest-filter / -k / etc. without us having to
            # re-list them here.
            FORWARDED_ARGS+=("${arg}")
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight: ensure coverage tooling is on PATH inside the active conda env.
# We do NOT pull pytest-cov in unconditionally because the upstream cuopt_dev
# env may already ship it (and we don't want to clobber the resolver).
# ---------------------------------------------------------------------------
ensure_python_coverage_tools() {
    require_cmd python

    local need_coverage=0 need_pytest_cov=0
    python -c 'import coverage' 2>/dev/null   || need_coverage=1
    python -c 'import pytest_cov' 2>/dev/null || need_pytest_cov=1

    if [ "${need_coverage}" -eq 0 ] && [ "${need_pytest_cov}" -eq 0 ]; then
        log_info "coverage.py + pytest-cov already installed"
        return 0
    fi

    local pkgs=()
    [ "${need_coverage}"   -eq 1 ] && pkgs+=("coverage")
    [ "${need_pytest_cov}" -eq 1 ] && pkgs+=("pytest-cov")
    log_step "Installing missing coverage tools: ${pkgs[*]}"
    python -m pip install --no-input -q "${pkgs[@]}" \
        || die "failed to pip install ${pkgs[*]} into the active env"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
generate_reports() {
    log_step "Generating Python coverage reports"

    # ----------------------------------------------------------------------
    # Per-suite diagnostic dump BEFORE combining. This is the one place
    # where it's still possible to attribute coverage data to a specific
    # suite -- after combine() the data file is one merged blob. If a
    # suite shows 0 measured files here, no amount of report-time fiddling
    # will recover its data; the bug is upstream in the test invocation.
    # ----------------------------------------------------------------------
    log_step "Per-suite coverage inventory"
    python - "${PER_SUITE_DATA_FILES[@]}" <<'PY' || true
"""Enumerate per-suite fragments without consuming/modifying them.

We use CoverageData.update() directly (rather than Coverage(...).combine())
so we never touch the on-disk fragments and never trigger rcfile-based
auto-suffix logic that would create stray .coverage.<host>.<pid>.<rand>
files in RESULTS_DIR.
"""
import glob, os, sys
from coverage.sqldata import CoverageData

def classify(f, buckets):
    if "python-coverage-shim" in f:
        buckets["sitecustomize"] += 1
    elif "/cuopt_server/" in f or "cuopt_server" in f.split(os.sep):
        buckets["cuopt_server"] += 1
    elif "/cuopt_sh_client/" in f or "cuopt_sh_client" in f.split(os.sep):
        buckets["cuopt_sh_client"] += 1
    elif "/cuopt/cuopt/" in f or "cuopt" in f.split(os.sep):
        buckets["cuopt"] += 1
    else:
        buckets["other"] += 1

for base in sys.argv[1:]:
    label = os.path.basename(base)
    # pytest-cov calls Coverage.combine() at end-of-session and saves the
    # merged data file to the BARE base path (no suffix). The subprocess
    # shim (no combine() call) leaves parallel-suffixed files behind
    # instead. We accept both forms as valid input for this suite.
    fragments = []
    if os.path.isfile(base):
        fragments.append(base)
    fragments.extend(sorted(glob.glob(base + ".*")))
    print(f"\n[{label}]")
    print(f"  fragments on disk: {len(fragments)}")
    if not fragments:
        print("  (no data; suite either did not run with --cov or its")
        print("   per-suite COVERAGE_FILE wiring is broken)")
        continue
    merged = CoverageData(basename=base + ".__inspect__", no_disk=True)
    for f in fragments:
        piece = None
        try:
            piece = CoverageData(basename=f)
            piece.read()
            merged.update(piece)
        except Exception as e:
            print(f"  WARN: could not read {os.path.basename(f)}: {e}")
        finally:
            # Release this piece's SQLite handle before the next iteration
            # so we don't collide on coverage's shared in-memory cache URI
            # (manifested as "database other_db is already in use" on
            # subsequent reads in the same interpreter).
            if piece is not None:
                _dbs = getattr(piece, "_dbs", None)
                if isinstance(_dbs, dict):
                    for _db in list(_dbs.values()):
                        _close = getattr(_db, "close", None)
                        if callable(_close):
                            try:
                                _close()
                            except Exception:
                                pass
                    _dbs.clear()
    files = sorted(merged.measured_files())
    buckets = {"cuopt": 0, "cuopt_server": 0, "cuopt_sh_client": 0,
               "sitecustomize": 0, "other": 0}
    for f in files:
        classify(f, buckets)
    print(f"  measured files:    {len(files)}")
    print(f"  by bucket:         {buckets}")
PY

    # ----------------------------------------------------------------------
    # Explicit combine over per-suite globs.
    #
    # We deliberately do NOT use `coverage combine <dir>` here because that
    # would only pick up fragments matching the current $COVERAGE_FILE's
    # basename -- it can't merge files with three different base names in
    # one call. So we shell-expand each glob into a list of files and pass
    # them positionally; coverage treats positional args as files-to-read
    # regardless of their basename.
    # ----------------------------------------------------------------------
    log_step "Combining per-suite coverage data"
    local fragments=()
    for _base in "${PER_SUITE_DATA_FILES[@]}"; do
        # pytest-cov runs Coverage.combine()+save() at end-of-session and
        # writes ONE consolidated data file at ${_base} (no suffix), having
        # consumed all parallel-suffixed children. The subprocess shim
        # bypasses pytest-cov, so it leaves `${_base}.<host>.<pid>.<rand>`
        # files behind. We accept both forms as inputs to the final merge:
        # bash globbing requires a literal dot for `${_base}.*`, so we add
        # the bare ${_base} file separately.
        local _matches=()
        [ -f "${_base}" ] && _matches+=("${_base}")
        shopt -s nullglob
        _matches+=( "${_base}".* )
        shopt -u nullglob
        if [ ${#_matches[@]} -gt 0 ]; then
            fragments+=("${_matches[@]}")
        fi
    done
    if [ ${#fragments[@]} -eq 0 ]; then
        die "no per-suite coverage fragments found -- did any pytest invocation actually run with --cov?"
    fi
    log_info "merging ${#fragments[@]} fragment file(s) into ${COVERAGE_DATA_FILE}"
    # Wipe the destination first so combine() starts fresh; otherwise a
    # stale .coverage file from a previous run would survive untouched and
    # leak its data into this run's report.
    rm -f "${COVERAGE_DATA_FILE}"

    # ----------------------------------------------------------------------
    # Per-fragment combine in a fresh subprocess.
    #
    # Previously we passed all fragments to ONE `coverage combine` call
    # inside a single Python interpreter. That fails for the cuopt_service
    # suite: cuopt_service forks its workers from a single parent process
    # whose `Coverage` object is duplicated by fork(), so every worker's
    # fragment carries the SAME internal SQLite shared-cache identifier.
    # When the in-process combine attaches the 2nd, 3rd, ... cuopt_service
    # fragment, SQLite refuses with "database other_db is already in use"
    # because the previous attach's shared-cache namespace is still bound
    # for the lifetime of the Python process.
    #
    # Spawning a fresh `python -m coverage combine --append --keep <one>`
    # per fragment sidesteps the issue: each invocation owns its own
    # SQLite shared-cache namespace, so a collision is structurally
    # impossible. `--append` is what makes the accumulation work --
    # without it, each call would wipe the destination. `--keep` retains
    # the per-suite fragments so subsequent `coverage debug data` /
    # per-suite inventory steps remain reproducible.
    #
    # Cost: N extra process spawns (~10 today, < 30s wall time). Benefit:
    # the cuopt_service worker fragments actually land in the merged data
    # file, which is worth several percentage points of cuopt_server
    # coverage with zero new tests required.
    # ----------------------------------------------------------------------
    local merged=0 skipped=0
    local _frag _out _rc
    for _frag in "${fragments[@]}"; do
        _rc=0
        _out=$(COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage combine \
                --append --keep "${_frag}" 2>&1) || _rc=$?
        if [ "${_rc}" -eq 0 ]; then
            merged=$(( merged + 1 ))
        else
            skipped=$(( skipped + 1 ))
            log_warn "  combine rc=${_rc} for $(basename "${_frag}"):"
            # Indent each line of the captured output for readability.
            while IFS= read -r _line; do
                [ -n "${_line}" ] && log_warn "    ${_line}"
            done <<< "${_out}"
        fi
    done
    log_info "merged ${merged}/${#fragments[@]} fragment(s) (skipped ${skipped})"
    if [ "${merged}" -eq 0 ]; then
        die "coverage combine failed for every fragment; aborting report generation"
    fi

    if [ ! -s "${COVERAGE_DATA_FILE}" ]; then
        die "combine produced no data at ${COVERAGE_DATA_FILE}"
    fi

    # ----------------------------------------------------------------------
    # Diagnostic dump on the combined data file -- the ground truth for
    # what reports will see.
    # ----------------------------------------------------------------------
    log_step "Combined coverage data inspection (diagnostic)"
    COVERAGE_FILE="${COVERAGE_DATA_FILE}" python - <<'PY' || true
import coverage, os, sys
c = coverage.Coverage(data_file=os.environ["COVERAGE_FILE"])
c.load()
files = sorted(c.get_data().measured_files())
print(f"Total measured files: {len(files)}")
buckets = {"cuopt": 0, "cuopt_server": 0, "cuopt_sh_client": 0,
           "sitecustomize": 0, "other": 0}
for f in files:
    if "python-coverage-shim" in f:
        buckets["sitecustomize"] += 1
    elif "/cuopt_server/" in f or "cuopt_server" in f.split(os.sep):
        buckets["cuopt_server"] += 1
    elif "/cuopt_sh_client/" in f or "cuopt_sh_client" in f.split(os.sep):
        buckets["cuopt_sh_client"] += 1
    elif "/cuopt/cuopt/" in f or "cuopt" in f.split(os.sep):
        buckets["cuopt"] += 1
    else:
        buckets["other"] += 1
print(f"By bucket: {buckets}")
print("First 20 files (showing path forms actually stored):")
for f in files[:20]:
    print(f"  {f}")
if len(files) > 20:
    print(f"  ...and {len(files) - 20} more")
PY

    # ----------------------------------------------------------------------
    # Filtering strategy
    # ----------------------------------------------------------------------
    # Earlier we used absolute-path includes like
    #   /rocopt-release/python/cuopt/cuopt/*
    # but coverage records files under whatever path Python imported them
    # from, and that path form differs across the three test suites' rootdirs
    # (pytest-cov's per-suite display normalises but the data file does not).
    # The fnmatch pattern `*/python/cuopt/cuopt/*` matches BOTH the absolute
    # form `/rocopt-release/python/cuopt/cuopt/...` and any relativised form
    # that includes the canonical path segment. With `*` matching `/`, this
    # is robust.
    local incl="*/python/cuopt/cuopt/*,*/python/cuopt_server/cuopt_server/*,*/python/cuopt_self_hosted/cuopt_sh_client/*"
    local omit="*/tests/*,*/_deps/*,*/build/*,*/dist/*,*/conftest.py"
    local cov_args=(--include="${incl}" --omit="${omit}")

    log_step "Terminal report"
    {
        echo "rocopt Python coverage (coverage.py)"
        echo "Data: ${COVERAGE_DATA_FILE}"
        [ -n "${COVERAGE_CONFIG}" ] && echo "Config: ${COVERAGE_CONFIG}"
        echo "Suites: cuopt, cuopt_server, cuopt_self_hosted"
        echo ""
        echo "[ Unfiltered report -- everything coverage saw ]"
        COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage report \
            --omit="${omit}" 2>&1 | tail -80 || true
        echo ""
        echo "[ Filtered report -- our three packages only ]"
        COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage report \
            "${cov_args[@]}" --skip-covered 2>&1 || true
        echo ""
        echo "Per-package summary:"
        for pkg_glob in \
            "*/python/cuopt/cuopt/*" \
            "*/python/cuopt_server/cuopt_server/*" \
            "*/python/cuopt_self_hosted/cuopt_sh_client/*"
        do
            echo "--- ${pkg_glob} ---"
            COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage report \
                --include="${pkg_glob}" \
                --omit="${omit}" 2>/dev/null | tail -1 || true
        done
    } | tee "${REPORT_TXT}"

    log_step "HTML report"
    rm -rf "${REPORT_HTML}"
    mkdir -p "${REPORT_HTML}"
    COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage html \
        -d "${REPORT_HTML}" "${cov_args[@]}" \
        || log_warn "coverage html failed; continuing"

    log_step "Cobertura XML"
    COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage xml \
        -o "${REPORT_XML}" "${cov_args[@]}" \
        || log_warn "coverage xml failed; continuing"

    log_step "JSON report"
    COVERAGE_FILE="${COVERAGE_DATA_FILE}" python -m coverage json \
        -o "${REPORT_JSON}" "${cov_args[@]}" \
        || log_warn "coverage json failed; continuing"

    log_info "Terminal report: ${REPORT_TXT}"
    log_info "HTML report:     ${REPORT_HTML}/index.html"
    log_info "XML  report:     ${REPORT_XML}"
    log_info "JSON report:     ${REPORT_JSON}"

    # Mirror the C++ side: publish a platform-coverage JSON under /artifacts
    # using the same naming scheme so the downstream coverage uploader picks
    # up both files.
    local artifacts_folder="${ARTIFACTS_FOLDER:-/artifacts}"
    mkdir -p "${artifacts_folder}"
    local pub_json="${artifacts_folder}/coverage-py_code_coverage.json"
    if [ -s "${REPORT_JSON}" ]; then
        cp -f "${REPORT_JSON}" "${pub_json}"
        log_info "coverage.py export: ${pub_json}"
    else
        log_warn "no JSON report at ${REPORT_JSON}; nothing to publish at ${pub_json}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_cmd python curl

    ensure_python_coverage_tools

    mkdir -p "${RESULTS_DIR}"

    # Wipe any stale coverage data for ALL of our basenames (canonical
    # + per-suite + cuopt_service). coverage's append/combine machinery
    # assumes a fresh seed at the start of every coverage *run*; leaving
    # fragments from a previous invocation around can silently leak data
    # from one run's tests into the next run's report.
    rm -f "${COVERAGE_DATA_FILE}" "${COVERAGE_DATA_FILE}".*
    for _base in "${PER_SUITE_DATA_FILES[@]}"; do
        rm -f "${_base}" "${_base}".*
    done

    # Toggle coverage on in the in-container runner. The runner sets the
    # per-suite COVERAGE_FILE itself; we only export PYTHON_COVERAGE=1 and
    # the rcfile location.
    export PYTHON_COVERAGE=1
    [ -n "${COVERAGE_CONFIG}" ] && export PYTHON_COVERAGE_CONFIG="${COVERAGE_CONFIG}"

    # Default the cuopt_server suite into TestClient (in-process) mode
    # whenever coverage is collected. In-container-tests.sh reads this var
    # and switches to a per-file pytest loop that gives the parent pytest
    # process direct line coverage of the webserver + solver-worker code
    # paths -- worth several percentage points of cuopt_server coverage vs
    # the legacy real-server subprocess path.
    #
    # ${VAR:-1} preserves whatever the caller already exported (including
    # `0` to explicitly opt out for debugging), so this is a safe default,
    # not a forced override.
    export CUOPT_TEST_TESTCLIENT="${CUOPT_TEST_TESTCLIENT:-1}"

    # Subprocess coverage. cuopt_server tests fork a 3-level process tree
    # (pytest -> cuopt_service -> webserver + solver workers). Without
    # subprocess instrumentation the webserver / solver workers / per-GPU
    # processes report 0% even though the HTTP integration tests fully
    # exercise them.
    #
    # Mechanism: we prepend scripts/lib/python-coverage-shim/ onto PYTHONPATH.
    # That directory contains a sitecustomize.py which Python auto-imports at
    # interpreter startup -- so every child process (and child-of-child) sees
    # it. The shim chains into any pre-existing sitecustomize (conda ships
    # one), then -- only if COVERAGE_PROCESS_START is set -- calls
    # coverage.process_startup() to begin tracing.
    #
    # We rely on this explicit shim instead of the pip-installed
    # `coverage.pth` because conda environments can silently disable .pth
    # processing (PYTHONNOUSERSITE, ENABLE_USER_SITE=False, custom site.py
    # patches), which silently produces 0% subprocess coverage with no error.
    #
    # The .coveragerc referenced by COVERAGE_PROCESS_START must have
    # `parallel = True` so children write .coverage.<host>.<pid>.<n> fragments
    # instead of clobbering each other; `sigterm = True` ensures the
    # cuopt_service subprocess flushes when SIGTERMed at shutdown.
    local shim_dir="${_SCRIPT_DIR}/python-coverage-shim"
    if [ -f "${shim_dir}/sitecustomize.py" ]; then
        if [ -n "${PYTHONPATH:-}" ]; then
            export PYTHONPATH="${shim_dir}:${PYTHONPATH}"
        else
            export PYTHONPATH="${shim_dir}"
        fi
    else
        log_warn "subprocess coverage shim missing: ${shim_dir}/sitecustomize.py"
    fi
    if [ -n "${COVERAGE_CONFIG}" ]; then
        export COVERAGE_PROCESS_START="${COVERAGE_CONFIG}"
        export COVERAGE_RCFILE="${COVERAGE_CONFIG}"
    fi

    # One-shot self-test: spawn a Python subprocess and check whether the
    # shim caused it to drop a .coverage.* fragment. Fast (<1s) and gives an
    # obvious error message if the chain is broken before spending 30min on
    # the full suite.
    if [ -n "${COVERAGE_PROCESS_START:-}" ]; then
        local shim_ok
        shim_ok="$(python - <<'PY' 2>/dev/null || echo "ERROR"
import glob, os, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as d:
    env = os.environ.copy()
    env["COVERAGE_FILE"] = os.path.join(d, ".coverage")
    # Tiny payload so the tracer actually has a line to record.
    subprocess.check_call(
        [sys.executable, "-c", "x = sum(range(10))"],
        env=env,
    )
    frags = glob.glob(os.path.join(d, ".coverage*"))
    print("ACTIVE" if frags else "INACTIVE")
PY
)"
        if [ "${shim_ok}" = "ACTIVE" ]; then
            log_info "subprocess coverage shim verified (child Python wrote a coverage fragment)"
        else
            log_warn "subprocess coverage shim self-test returned '${shim_ok}' -- subprocess coverage may be 0%"
            log_warn "  PYTHONPATH=${PYTHONPATH:-<unset>}"
            log_warn "  COVERAGE_PROCESS_START=${COVERAGE_PROCESS_START:-<unset>}"
        fi
    fi

    log_step "Running Python tests under coverage"
    log_info "Per-suite data files (in-container-tests.sh sets COVERAGE_FILE per suite):"
    log_info "  cuopt:             ${COVERAGE_DATA_FILE_CUOPT}"
    log_info "  cuopt_server:      ${COVERAGE_DATA_FILE_CUOPT_SERVER}"
    log_info "  cuopt_sh_client:   ${COVERAGE_DATA_FILE_CUOPT_SH_CLIENT}"
    log_info "  cuopt_service:     ${COVERAGE_DATA_FILE_CUOPT_SERVICE} (subprocess shim)"
    log_info "  combined report:   ${COVERAGE_DATA_FILE}"
    [ -n "${COVERAGE_CONFIG:-}" ] && log_info "PYTHON_COVERAGE_CONFIG=${COVERAGE_CONFIG}"
    [ -n "${COVERAGE_PROCESS_START:-}" ] && log_info "COVERAGE_PROCESS_START=${COVERAGE_PROCESS_START} (subprocess instrumentation enabled)"

    local test_args=(--python)
    [ "${SKIP_DATASETS}" -eq 1 ] && test_args+=(--skip-datasets)
    # Allow callers to pass extra pytest args through `--`; we already
    # captured everything else verbatim in FORWARDED_ARGS above.
    for a in "${FORWARDED_ARGS[@]}"; do
        case "${a}" in
            --skip-datasets) : ;;  # already added
            *) test_args+=("${a}") ;;
        esac
    done

    local test_ec=0
    bash "${_SCRIPT_DIR}/in-container-tests.sh" "${test_args[@]}" || test_ec=$?

    # Per-suite fragment inventory. Each suite's COVERAGE_FILE was a
    # different base name; pytest-cov writes parallel-suffixed files
    # `<base>.<host>.<pid>.<rand>.combine` (or .Hxh from the tracer
    # itself). 0 fragments for a given base means that suite never wrote
    # any data -- almost always a sign the per-suite COVERAGE_FILE wiring
    # is wrong, not that the tests didn't run.
    log_step "Coverage fragments produced (per-suite)"
    for _base in "${PER_SUITE_DATA_FILES[@]}"; do
        # Same dual-form match as the combine step: bare ${_base} (pytest-cov
        # post-combine result) OR parallel-suffixed ${_base}.<host>.<pid>.<rand>
        # (subprocess shim, not consumed by combine).
        local _n=0
        [ -f "${_base}" ] && _n=$(( _n + 1 ))
        _n=$(( _n + $(find "$(dirname "${_base}")" -maxdepth 1 \
            -name "$(basename "${_base}").*" -type f 2>/dev/null | wc -l) ))
        if [ "${_n}" -gt 0 ]; then
            log_info "  $(basename "${_base}"): ${_n} file(s) on disk"
        else
            log_warn "  $(basename "${_base}"): 0 fragments -- suite produced no coverage data"
        fi
    done

    generate_reports

    if [ "${test_ec}" -ne 0 ]; then
        log_error "Python tests exited with ${test_ec}; coverage reports were still generated"
        exit 1
    fi

    log_step "Phase D Python coverage complete"
}

main "$@"
