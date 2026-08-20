#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# In-container test driver for rocopt.
#
# This script is the single source of truth for "how do you run the rocopt
# tests."  It is invoked by the host-side wrapper (scripts/run-tests.sh) but
# is also runnable directly inside an `exec`'d container, e.g.:
#
#   docker exec -it <container> bash /rocopt-release/scripts/lib/in-container-tests.sh --all
#
# It assumes:
#   * The repository is checked out at /rocopt-release (or $ROCOPT_DIR).
#   * The conda env `cuopt_dev` exists and has cuopt/cudf installed.
#   * For C++ tests: gtest binaries have been built at
#     cpp/build/latest/gtests/libcuopt/*_TEST.
#
# Output:
#   * Streamed test logs to STDERR.
#   * JUnit XML written to ${RESULTS_DIR}/{ctest,pytest}.xml (and per-binary
#     gtest XMLs when ctest is unavailable).
#   * Final RESULT line on STDOUT, machine-parseable.
#
# Exit codes (matches host-side scripts):
#   0  all selected suites passed
#   1  one or more suites had failures
#   2  infrastructure failure (env missing, no test binaries, etc.)
#   3  usage error

set -euo pipefail

# ---------------------------------------------------------------------------
# Source common helpers (lives next to this script).
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${_SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Config (environment-overridable)
# ---------------------------------------------------------------------------
ROCOPT_DIR="${ROCOPT_DIR:-/rocopt-release}"
CONDA_DIR="${CONDA_DIR:-/root/miniforge3}"
CONDA_ENV="${CONDA_ENV:-cuopt_dev}"
RESULTS_DIR="${RESULTS_DIR:-${ROCOPT_DIR}/test-results}"

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
RUN_CPP=0
RUN_PYTHON=0
PY_KEYWORD=""
CTEST_FILTER=""
PYTEST_EXTRA=()
SKIP_DATASETS=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--cpp] [--python] [--all]
                       [--ctest-filter <regex>]
                       [-k <expr>]
                       [-- <extra pytest args>]

Run rocopt's C++ and/or Python test suites inside the container.

Suites:
  --cpp                   Run C++ gtests (cpp/build/latest/gtests/libcuopt/*_TEST)
  --python                Run pytest under python/cuopt/cuopt/tests
  --all                   Both (default if none specified)

Filters:
  --ctest-filter <regex>  Restrict ctest / gtest names by regex (gtest_filter)
  -k <expr>               Forwarded to pytest -k

Datasets:
  --skip-datasets         Don't run dataset download scripts (assume datasets
                          are already staged at \${ROCOPT_DIR}/datasets/).
                          Both C++ and Python suites consume these.

Anything after a literal '--' is forwarded verbatim to pytest.

Outputs JUnit XML to: \${RESULTS_DIR:-${ROCOPT_DIR}/test-results}
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cpp)              RUN_CPP=1; shift ;;
        --python)           RUN_PYTHON=1; shift ;;
        --all)              RUN_CPP=1; RUN_PYTHON=1; shift ;;
        --ctest-filter)     CTEST_FILTER="$2"; shift 2 ;;
        -k)                 PY_KEYWORD="$2"; shift 2 ;;
        --skip-datasets)    SKIP_DATASETS=1; shift ;;
        --)                 shift; PYTEST_EXTRA=("$@"); break ;;
        -h|--help)          usage; exit 0 ;;
        *)                  log_error "unknown arg: $1"; usage >&2; exit 3 ;;
    esac
done

# Default to --all if no suite was selected.
if [ "$RUN_CPP" -eq 0 ] && [ "$RUN_PYTHON" -eq 0 ]; then
    RUN_CPP=1
    RUN_PYTHON=1
fi

# ---------------------------------------------------------------------------
# Environment activation
# ---------------------------------------------------------------------------
log_step "Activating conda env: ${CONDA_ENV}"
# shellcheck disable=SC1091
source "${CONDA_DIR}/bin/activate" "${CONDA_ENV}" \
    || die "could not activate conda env '${CONDA_ENV}' under ${CONDA_DIR}"

mkdir -p "${RESULTS_DIR}"

cd "${ROCOPT_DIR}" || die "ROCOPT_DIR not found: ${ROCOPT_DIR}"

# Track per-suite outcomes so we can emit a structured summary at the end
# even when one suite fails (we still want to run the other to surface all
# breakage in a single CI run, rather than fail-fast and hide it).
CPP_RESULT="SKIP"
CPP_TESTS=0
CPP_FAILS=0
CPP_DURATION=0

PY_RESULT="SKIP"
PY_TESTS=0
PY_FAILS=0
PY_DURATION=0

# Per-Python-suite tracking (cuopt library / cuopt_server / cuopt_self_hosted).
# These feed into PY_TESTS / PY_FAILS / PY_DURATION at the end but are also
# kept individually so emit_summary can break out which suite owns which
# failures.
CUOPT_RESULT="SKIP";       CUOPT_TESTS=0;       CUOPT_FAILS=0;       CUOPT_DURATION=0
CUOPT_SRV_RESULT="SKIP";   CUOPT_SRV_TESTS=0;   CUOPT_SRV_FAILS=0;   CUOPT_SRV_DURATION=0
CUOPT_SH_RESULT="SKIP";    CUOPT_SH_TESTS=0;    CUOPT_SH_FAILS=0;    CUOPT_SH_DURATION=0

OVERALL_START=$(date +%s)

# ---------------------------------------------------------------------------
# C++ tests
# ---------------------------------------------------------------------------
# Strategy: prefer `ctest --output-junit` (clean, single XML).  Fall back to
# direct gtest binary invocation with --gtest_output=xml when ctest doesn't
# know about the tests (e.g. when CMake's gtest_discover_tests wasn't used).
run_cpp_tests() {
    log_step "Running C++ tests"
    local start; start=$(date +%s)
    local ctest_xml="${RESULTS_DIR}/ctest.xml"
    rm -f "${ctest_xml}"

    local cpp_build="${ROCOPT_CPP_BUILD_DIR:-${ROCOPT_DIR}/cpp/build}"
    if [ ! -d "${cpp_build}" ]; then
        log_error "C++ build directory not found: ${cpp_build}. Did you run ./build.sh libcuopt? Override with ROCOPT_CPP_BUILD_DIR."
        CPP_RESULT="ERROR"
        return 2
    fi

    # Probe ctest.  --show-only -N just lists; if it returns >0 tests, ctest
    # is the right tool.  Otherwise we drop to the direct-binary fallback.
    local ctest_count=0
    if command -v ctest >/dev/null 2>&1; then
        ctest_count=$(
            ctest --test-dir "${cpp_build}" -N 2>/dev/null \
                | awk '/Total Tests:/ {print $NF; exit}'
        )
        ctest_count="${ctest_count:-0}"
    fi

    local ec=0
    if [ "${ctest_count}" -gt 0 ]; then
        log_info "ctest sees ${ctest_count} test(s); using ctest --output-junit"
        local ctest_args=(--test-dir "${cpp_build}" --output-on-failure --output-junit "${ctest_xml}")
        [ -n "${CTEST_FILTER}" ] && ctest_args+=(-R "${CTEST_FILTER}")
        ctest "${ctest_args[@]}" || ec=$?
    else
        log_warn "ctest reports 0 tests; falling back to direct gtest binary invocation"
        run_gtest_binaries_fallback "${ctest_xml}" || ec=$?
    fi

    CPP_DURATION=$(( $(date +%s) - start ))

    # Parse XML for accurate counts.  parse_junit_summary handles missing
    # files gracefully (returns all-zeros), which lets us still emit a
    # structured summary even when the run crashed before producing XML.
    local summary; summary=$(parse_junit_summary "${ctest_xml}")
    # shellcheck disable=SC2086  # intentional word-splitting on summary
    eval "$(printf '%s' "${summary}" | awk '{
        for (i=1;i<=NF;i++) {
            split($i, kv, "=");
            printf "_%s=\"%s\"; ", toupper(kv[1]), kv[2]
        }
    }')"
    CPP_TESTS="${_TESTS:-0}"
    CPP_FAILS=$(( ${_FAILURES:-0} + ${_ERRORS:-0} ))

    if [ "${ec}" -eq 0 ] && [ "${CPP_FAILS}" -eq 0 ]; then
        CPP_RESULT="PASS"
        log_info "C++ tests PASSED (${CPP_TESTS} tests, $(fmt_duration "${CPP_DURATION}"))"
        return 0
    else
        CPP_RESULT="FAIL"
        log_error "C++ tests FAILED (${CPP_FAILS}/${CPP_TESTS} failed, exit=${ec}, $(fmt_duration "${CPP_DURATION}"))"
        return 1
    fi
}

# Fallback: when CMake's gtest_discover_tests wasn't used, ctest doesn't see
# the binaries.  We invoke each *_TEST binary directly with gtest's native
# --gtest_output=xml: support and concatenate the per-binary XMLs into a
# single ctest.xml-shaped <testsuites> document so downstream parsing is
# uniform.
run_gtest_binaries_fallback() {
    local out_xml="$1"
    local installed="${INSTALL_PREFIX:-${CONDA_PREFIX:-/usr}}/bin/gtests/libcuopt/"
    local devcontainer="${ROCOPT_DIR}/cpp/build/latest/gtests/libcuopt/"
    local gtest_dir=""

    if [ -d "${installed}" ]; then
        gtest_dir="${installed}"
    elif [ -d "${devcontainer}" ]; then
        gtest_dir="${devcontainer}"
    else
        log_error "no gtest binaries found.  Searched:"
        log_error "  ${installed}"
        log_error "  ${devcontainer}"
        return 2
    fi

    log_info "running gtests from: ${gtest_dir}"
    local per_xml_dir="${RESULTS_DIR}/gtest-xml"
    mkdir -p "${per_xml_dir}"
    rm -f "${per_xml_dir}"/*.xml

    local overall_ec=0
    local found=0
    for gt in "${gtest_dir}"/*_TEST; do
        [ -x "${gt}" ] || continue
        found=1
        local name; name=$(basename "${gt}")
        local args=(--gtest_output="xml:${per_xml_dir}/${name}.xml")
        [ -n "${CTEST_FILTER}" ] && args+=("--gtest_filter=${CTEST_FILTER}")
        log_info "running: ${name}"
        if ! "${gt}" "${args[@]}"; then
            overall_ec=1
        fi
    done

    if [ "${found}" -eq 0 ]; then
        log_error "no *_TEST binaries found in ${gtest_dir}"
        return 2
    fi

    # Stitch per-binary XMLs into a single <testsuites> document.  We drop
    # each file's <?xml ...?> declaration and outer <testsuites> wrapper,
    # keeping the inner <testsuite> elements.  This is good enough for
    # parse_junit_summary's awk-on-attributes approach.
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        # Aggregate counts across all per-binary files for the wrapper
        # <testsuites> element.
        local agg_t=0 agg_f=0 agg_e=0 agg_s=0
        for x in "${per_xml_dir}"/*.xml; do
            [ -s "$x" ] || continue
            local s; s=$(parse_junit_summary "$x")
            local _T _F _E _S
            # shellcheck disable=SC2034
            eval "$(printf '%s' "$s" | sed 's/\([a-z]*\)=/_\U\1=/g')"
            agg_t=$(( agg_t + ${_TESTS:-0} ))
            agg_f=$(( agg_f + ${_FAILURES:-0} ))
            agg_e=$(( agg_e + ${_ERRORS:-0} ))
            agg_s=$(( agg_s + ${_SKIPPED:-0} ))
        done
        printf '<testsuites tests="%d" failures="%d" errors="%d" skipped="%d">\n' \
            "${agg_t}" "${agg_f}" "${agg_e}" "${agg_s}"
        for x in "${per_xml_dir}"/*.xml; do
            [ -s "$x" ] || continue
            sed -n '/<testsuite[ >]/,/<\/testsuite>/p' "$x"
        done
        printf '</testsuites>\n'
    } > "${out_xml}"

    return "${overall_ec}"
}

# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------
# Both the C++ gtests and the pytest suites consume external datasets that
# are not bundled in the image.  The repo ships three download scripts that
# pull them at runtime:
#
#   datasets/get_test_data.sh                          (routing: VRP, etc.)
#   datasets/linear_programming/download_pdlp_test_dataset.sh   (LP / PDLP)
#   datasets/mip/download_miplib_test_dataset.sh                (MIP / MIPLIB)
#
# We download once up front (before either suite runs) and always fresh —
# no host bind-mount, no marker file.  Each run starts from a clean
# container, so this is the expected cost of test runs.  The PDLP and MIPLIB
# scripts are idempotent (S3 sync / wget --continue), get_test_data.sh is
# destructive (rm -rf each subdir then re-download).
#
# RAPIDS_DATASET_ROOT_DIR is consumed by both the pytest fixtures and the
# C++ test binaries to locate the downloaded data.  Trailing slash matches
# the upstream ci/test_python.sh convention.
prepare_datasets() {
    log_step "Preparing test datasets"

    if [ "${SKIP_DATASETS}" -eq 1 ]; then
        log_warn "--skip-datasets passed; assuming datasets are pre-staged"
        export RAPIDS_DATASET_ROOT_DIR="${ROCOPT_DIR}/datasets/"
        return 0
    fi

    require_cmd wget tar unzip

    cd "${ROCOPT_DIR}"

    # Use return 1 (not die) so the caller can still emit a structured
    # RESULT line with cpp=ERROR python=ERROR rather than exiting silently.
    log_info "1/3 PDLP datasets"
    if ! ./datasets/linear_programming/download_pdlp_test_dataset.sh; then
        log_error "PDLP dataset download failed"
        return 1
    fi

    log_info "2/3 MIPLIB datasets"
    if ! ./datasets/mip/download_miplib_test_dataset.sh; then
        log_error "MIPLIB dataset download failed"
        return 1
    fi

    log_info "3/3 Routing datasets (get_test_data.sh)"
    if ! ( cd "${ROCOPT_DIR}/datasets" && ./get_test_data.sh ); then
        log_error "routing dataset download failed"
        return 1
    fi

    export RAPIDS_DATASET_ROOT_DIR="${ROCOPT_DIR}/datasets/"
    log_info "RAPIDS_DATASET_ROOT_DIR=${RAPIDS_DATASET_ROOT_DIR}"
}

# ---------------------------------------------------------------------------
# Python tests
# ---------------------------------------------------------------------------
# Three independent suites live under python/:
#
#   1. cuopt              -> python/cuopt/cuopt/tests
#                            (upstream wrapper: ci/run_cuopt_pytests.sh)
#   2. cuopt_server       -> python/cuopt_server/cuopt_server/tests
#                            (upstream wrapper: ci/run_cuopt_server_pytests.sh)
#                            Needs ROCM_HOME=/opt/rocm so the in-process HIP
#                            handles initialize the same way the production
#                            container does; without it, cuopt_server fixtures
#                            occasionally probe the wrong CUDA-style paths.
#   3. cuopt_self_hosted  -> python/cuopt_self_hosted/tests
#                            Requires a running cuopt_service on a known port
#                            (we use 5050 -- the upstream 5555 is held by
#                            leftover sessions in the ROCm test container).
#                            We start the server here, wait for /cuopt/health,
#                            run pytest, then SIGTERM the server.
#
# run_python_tests() is a thin dispatcher that calls all three in order and
# aggregates per-suite counts into PY_TESTS / PY_FAILS / PY_DURATION.  Each
# sub-runner is independent so failures in one don't short-circuit the others.

# Helper: shared logic for invoking pytest with --junitxml, -k, PYTEST_EXTRA,
# and (optionally) per-suite coverage. Each suite passes its own pytest
# wrapper path and JUnit destination.
#
# When PYTHON_COVERAGE=1 is set in the environment (typically by
# run-python-coverage.sh), $cov_pkg is appended as `--cov=<pkg>` and pytest
# runs with a per-suite COVERAGE_FILE (passed via $cov_data_file). We
# deliberately do NOT use --cov-append: each suite writes its own data file
# so that pytest-cov's internal `combining_cov.combine()` -- which globs
# `<data_file>.*` and DELETES every match -- can't accidentally consume
# fragments from a sibling suite or from the long-running cuopt_service
# subprocess workers. Suite outputs are merged by run-python-coverage.sh's
# final `coverage combine` step.
#
# Arg 4 ($cov_data_file) is the absolute path to use as COVERAGE_FILE for
# this suite. If unset, coverage uses whatever COVERAGE_FILE the caller
# exported (legacy / debugging).
_invoke_pytest_wrapper() {
    local wrapper="$1"
    local junit="$2"
    local cov_pkg="${3:-}"
    local cov_data_file="${4:-}"

    local args=("--junitxml=${junit}")
    [ -n "${PY_KEYWORD}" ] && args+=(-k "${PY_KEYWORD}")

    local pytest_env=()
    if [ "${PYTHON_COVERAGE:-0}" -eq 1 ] && [ -n "${cov_pkg}" ]; then
        local cov_config=""
        if [ -n "${PYTHON_COVERAGE_CONFIG:-}" ]; then
            cov_config="${PYTHON_COVERAGE_CONFIG}"
        elif [ -f "${ROCOPT_DIR}/.coveragerc" ]; then
            cov_config="${ROCOPT_DIR}/.coveragerc"
        fi
        args+=(--cov="${cov_pkg}")
        [ -n "${cov_config}" ] && args+=(--cov-config="${cov_config}")
        if [ -n "${cov_data_file}" ]; then
            pytest_env+=("COVERAGE_FILE=${cov_data_file}")
        fi
    fi

    if [ ${#PYTEST_EXTRA[@]} -gt 0 ]; then
        args+=("${PYTEST_EXTRA[@]}"); fi

    if [ ${#pytest_env[@]} -gt 0 ]; then
        env "${pytest_env[@]}" "${wrapper}" "${args[@]}"
    else
        "${wrapper}" "${args[@]}"
    fi
}

# --- 1/3 cuopt library --------------------------------------------------------
run_cuopt_tests() {
    log_step "Running cuopt library Python tests"
    local start; start=$(date +%s)
    local junit="${RESULTS_DIR}/pytest-cuopt.xml"
    rm -f "${junit}"

    local wrapper="${ROCOPT_DIR}/ci/run_cuopt_pytests.sh"
    if [ ! -x "${wrapper}" ]; then
        log_error "pytest wrapper not found or not executable: ${wrapper}"
        CUOPT_RESULT="ERROR"
        return 2
    fi

    local ec=0
    local cov_data=""
    [ "${PYTHON_COVERAGE:-0}" -eq 1 ] && cov_data="${RESULTS_DIR}/python-coverage.cuopt"
    _invoke_pytest_wrapper "${wrapper}" "${junit}" cuopt "${cov_data}" || ec=$?

    CUOPT_DURATION=$(( $(date +%s) - start ))

    local summary; summary=$(parse_junit_summary "${junit}")
    local _TESTS _FAILURES _ERRORS _SKIPPED
    # shellcheck disable=SC2034
    eval "$(printf '%s' "${summary}" | sed 's/\([a-z]*\)=/_\U\1=/g')"
    CUOPT_TESTS="${_TESTS:-0}"
    CUOPT_FAILS=$(( ${_FAILURES:-0} + ${_ERRORS:-0} ))

    if [ "${ec}" -eq 0 ] && [ "${CUOPT_FAILS}" -eq 0 ]; then
        CUOPT_RESULT="PASS"
        log_info "cuopt PASSED (${CUOPT_TESTS} tests, $(fmt_duration "${CUOPT_DURATION}"))"
        return 0
    else
        CUOPT_RESULT="FAIL"
        log_error "cuopt FAILED (${CUOPT_FAILS}/${CUOPT_TESTS} failed, exit=${ec}, $(fmt_duration "${CUOPT_DURATION}"))"
        return 1
    fi
}

# Per-file pytest loop for cuopt_server, used when CUOPT_TEST_TESTCLIENT=1.
#
# Why per-file: in TestClient mode the FastAPI app, solver-worker
# multiprocessing pool, and uvicorn event loop all live in the same
# interpreter as pytest. Running every test_*.py in a single pytest
# invocation accumulates state across modules (lingering futures, worker
# pool handles, monkeypatched signal handlers) which produces sporadic
# failures and lower coverage. Restarting the interpreter between files
# eliminates that leakage, and --cov-append keeps the coverage data
# accumulating into the same per-suite COVERAGE_FILE so the final combine
# step sees one consolidated set of fragments.
#
# Each file's JUnit XML is written under <merged_junit>.per-file/ and
# stitched into a single <testsuites>-wrapped document at the canonical
# merged-junit path so parse_junit_summary continues to see one set of
# aggregated counts (same approach as run_gtest_binaries_fallback).
_run_cuopt_server_tests_per_file() {
    local merged_junit="$1"
    local cov_data_file="${2:-}"

    local pkg_dir="${ROCOPT_DIR}/python/cuopt_server/cuopt_server"
    local tests_dir="${pkg_dir}/tests"
    if [ ! -d "${tests_dir}" ]; then
        log_error "cuopt_server tests dir not found: ${tests_dir}"
        return 2
    fi

    # Collect test_*.py under tests/ (non-recursive, sorted for reproducible
    # ordering across runs).
    local test_files=()
    local f
    while IFS= read -r -d '' f; do
        test_files+=("${f}")
    done < <(find "${tests_dir}" -maxdepth 1 -type f -name 'test_*.py' -print0 \
             | sort -z)
    if [ ${#test_files[@]} -eq 0 ]; then
        log_warn "no cuopt_server test files matched test_*.py under ${tests_dir}"
        return 1
    fi
    log_info "cuopt_server: ${#test_files[@]} test file(s) to run per-file"

    # Per-file JUnit XMLs go under merged_junit.per-file/; wipe stale output
    # first so a previous run's files can't leak into this run's aggregated
    # counts.
    local per_xml_dir="${merged_junit}.per-file"
    rm -rf "${per_xml_dir}"
    mkdir -p "${per_xml_dir}"

    # Pre-build coverage args once -- identical for every per-file call.
    # --cov-append is the load-bearing flag here: without it the second
    # file's invocation would wipe the first file's data.
    local cov_args=()
    if [ "${PYTHON_COVERAGE:-0}" -eq 1 ]; then
        local cov_config=""
        if [ -n "${PYTHON_COVERAGE_CONFIG:-}" ]; then
            cov_config="${PYTHON_COVERAGE_CONFIG}"
        elif [ -f "${ROCOPT_DIR}/.coveragerc" ]; then
            cov_config="${ROCOPT_DIR}/.coveragerc"
        fi
        cov_args+=(--cov=cuopt_server --cov-append)
        [ -n "${cov_config}" ] && cov_args+=(--cov-config="${cov_config}")
    fi

    # Wipe any stale per-suite coverage data so the FIRST --cov-append
    # starts from a clean slate. (Subsequent files append correctly because
    # we hold cov_data_file constant across all invocations.) Both the bare
    # base file (pytest-cov post-combine output) and parallel-suffixed
    # subprocess fragments are cleared.
    [ -n "${cov_data_file}" ] && rm -f "${cov_data_file}" "${cov_data_file}".*

    local kw_args=()
    [ -n "${PY_KEYWORD:-}" ] && kw_args+=(-k "${PY_KEYWORD}")

    local overall_ec=0
    local file_rc file_name per_junit
    for f in "${test_files[@]}"; do
        file_name="$(basename "${f}" .py)"
        per_junit="${per_xml_dir}/${file_name}.xml"
        log_info "[per-file] ${file_name}"
        # Bypass ci/run_cuopt_server_pytests.sh: it hard-appends `tests` to
        # the pytest args, which would re-run the whole suite for every
        # file. Replicate its `cd` + --cache-clear behavior directly.
        file_rc=0
        if [ -n "${cov_data_file}" ]; then
            ( cd "${pkg_dir}" \
                && COVERAGE_FILE="${cov_data_file}" \
                   pytest --cache-clear \
                       --junitxml="${per_junit}" \
                       "${cov_args[@]}" \
                       "${kw_args[@]}" \
                       "${PYTEST_EXTRA[@]}" \
                       "${f}" ) || file_rc=$?
        else
            ( cd "${pkg_dir}" \
                && pytest --cache-clear \
                       --junitxml="${per_junit}" \
                       "${cov_args[@]}" \
                       "${kw_args[@]}" \
                       "${PYTEST_EXTRA[@]}" \
                       "${f}" ) || file_rc=$?
        fi
        # pytest exit codes: 0=ok, 1=failures, 2=interrupted, 3=internal err,
        # 4=usage err, 5=no tests collected. Treat 5 as benign (an empty or
        # all-skipped file is not a suite failure); propagate everything else
        # and track the worst rc as the function's overall return code.
        if [ "${file_rc}" -eq 5 ]; then
            log_info "[per-file] ${file_name}: no tests collected (treating as benign)"
            continue
        fi
        if [ "${file_rc}" -ne 0 ]; then
            log_warn "[per-file] ${file_name} exited ${file_rc} (continuing; final summary will reflect failures)"
            [ "${file_rc}" -gt "${overall_ec}" ] && overall_ec=${file_rc}
        fi
    done

    # Merge per-file JUnit XMLs into one canonical document. Same shape as
    # run_gtest_binaries_fallback: an aggregated <testsuites> wrapper with
    # the per-file <testsuite> blocks concatenated inside, so existing
    # parse_junit_summary logic keeps working unchanged.
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        local agg_t=0 agg_f=0 agg_e=0 agg_s=0
        local x s _TESTS _FAILURES _ERRORS _SKIPPED
        for x in "${per_xml_dir}"/*.xml; do
            [ -s "$x" ] || continue
            s=$(parse_junit_summary "$x")
            # shellcheck disable=SC2034
            eval "$(printf '%s' "$s" | sed 's/\([a-z]*\)=/_\U\1=/g')"
            agg_t=$(( agg_t + ${_TESTS:-0} ))
            agg_f=$(( agg_f + ${_FAILURES:-0} ))
            agg_e=$(( agg_e + ${_ERRORS:-0} ))
            agg_s=$(( agg_s + ${_SKIPPED:-0} ))
        done
        printf '<testsuites tests="%d" failures="%d" errors="%d" skipped="%d">\n' \
            "${agg_t}" "${agg_f}" "${agg_e}" "${agg_s}"
        for x in "${per_xml_dir}"/*.xml; do
            [ -s "$x" ] || continue
            sed -n '/<testsuite[ >]/,/<\/testsuite>/p' "$x"
        done
        printf '</testsuites>\n'
    } > "${merged_junit}"

    return "${overall_ec}"
}

# --- 2/3 cuopt_server ---------------------------------------------------------
# Constraint: must export ROCM_HOME=/opt/rocm before pytest starts so that
# server-side fixtures (which call into HIP/RCCL during /cuopt/health probes)
# initialise against the same toolchain the production container uses.
# Setting it here keeps the contract local to this runner — neither the cuopt
# library suite nor the host wrapper need to know about it.
#
# Two execution modes are supported via CUOPT_TEST_TESTCLIENT:
#
#   unset / 0 (default, legacy):
#       Single pytest invocation through ci/run_cuopt_server_pytests.sh. The
#       fixtures spawn a real cuopt_service subprocess and talk to it over
#       HTTP. Worker coverage relies on the COVERAGE_PROCESS_START shim.
#
#   1 (in-process TestClient mode):
#       Tests use FastAPI's TestClient instead of forking a real server.
#       That gives the parent pytest process direct line coverage of the
#       webserver + solver-worker code, but forces us into a per-file pytest
#       loop (see _run_cuopt_server_tests_per_file above) to avoid
#       cross-module state leakage in a single interpreter.
run_cuopt_server_tests() {
    log_step "Running cuopt_server Python tests"
    local start; start=$(date +%s)
    local junit="${RESULTS_DIR}/pytest-cuopt-server.xml"
    rm -f "${junit}"

    local wrapper="${ROCOPT_DIR}/ci/run_cuopt_server_pytests.sh"
    if [ ! -x "${wrapper}" ]; then
        log_error "pytest wrapper not found or not executable: ${wrapper}"
        CUOPT_SRV_RESULT="ERROR"
        return 2
    fi

    local ec=0
    local cov_data=""
    [ "${PYTHON_COVERAGE:-0}" -eq 1 ] && cov_data="${RESULTS_DIR}/python-coverage.cuopt_server"
    # Subshell so the ROCM_HOME export doesn't leak into the self-hosted
    # runner (which spins up its own cuopt_service process and shouldn't
    # inherit a forced toolchain root).
    if [ "${CUOPT_TEST_TESTCLIENT:-0}" = "1" ]; then
        log_info "CUOPT_TEST_TESTCLIENT=1 — running cuopt_server tests per-file (in-process TestClient mode)"
        ( export ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
          export CUOPT_TEST_TESTCLIENT=1
          log_info "ROCM_HOME=${ROCM_HOME}"
          _run_cuopt_server_tests_per_file "${junit}" "${cov_data}" ) || ec=$?
    else
        ( export ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
          log_info "ROCM_HOME=${ROCM_HOME}"
          _invoke_pytest_wrapper "${wrapper}" "${junit}" cuopt_server "${cov_data}" ) || ec=$?
    fi

    CUOPT_SRV_DURATION=$(( $(date +%s) - start ))

    local summary; summary=$(parse_junit_summary "${junit}")
    local _TESTS _FAILURES _ERRORS _SKIPPED
    # shellcheck disable=SC2034
    eval "$(printf '%s' "${summary}" | sed 's/\([a-z]*\)=/_\U\1=/g')"
    CUOPT_SRV_TESTS="${_TESTS:-0}"
    CUOPT_SRV_FAILS=$(( ${_FAILURES:-0} + ${_ERRORS:-0} ))

    if [ "${ec}" -eq 0 ] && [ "${CUOPT_SRV_FAILS}" -eq 0 ]; then
        CUOPT_SRV_RESULT="PASS"
        log_info "cuopt_server PASSED (${CUOPT_SRV_TESTS} tests, $(fmt_duration "${CUOPT_SRV_DURATION}"))"
        return 0
    else
        CUOPT_SRV_RESULT="FAIL"
        log_error "cuopt_server FAILED (${CUOPT_SRV_FAILS}/${CUOPT_SRV_TESTS} failed, exit=${ec}, $(fmt_duration "${CUOPT_SRV_DURATION}"))"
        return 1
    fi
}

# --- 3/3 cuopt_self_hosted ----------------------------------------------------
# These tests talk to a running cuopt_service over HTTP, so we have to:
#   1. Kill any stale cuopt_service (port 5555 leaks across sessions in the
#      ROCm test container).
#   2. Start a fresh server on port 5050 (5050 is conventional and almost
#      never colliding; we logged 5555-collision issues already).
#   3. Wait up to 30s for /cuopt/health to return 200; bail out early if the
#      server PID dies before that.
#   4. Run pytest with CUOPT_SERVER_PORT=$PORT pointing the tests at our
#      freshly-started server.
#   5. SIGTERM the server on exit (success or failure) so subsequent runs
#      start clean.
run_cuopt_self_hosted_tests() {
    log_step "Running cuopt_self_hosted Python tests"
    local start; start=$(date +%s)
    local junit="${RESULTS_DIR}/pytest-cuopt-self-hosted.xml"
    rm -f "${junit}"

    # Clear stale server (defensive; safe if none exists).
    pkill -9 -f cuopt_service 2>/dev/null || true
    sleep 2

    local port="${CUOPT_SELF_HOSTED_PORT:-5050}"
    local server_log="${RESULTS_DIR}/cuopt_service.log"

    # The cuopt_service subprocess is instrumented via the python-coverage-shim
    # (PYTHONPATH-injected sitecustomize.py + COVERAGE_PROCESS_START in the
    # parent env). We give it its OWN COVERAGE_FILE so its fragments live
    # in a separate namespace from the pytest-cov data files; otherwise
    # pytest-cov's combine() would consume them mid-suite. The fragments
    # are merged back in by run-python-coverage.sh's final combine step.
    local server_cov_file=""
    if [ "${PYTHON_COVERAGE:-0}" -eq 1 ]; then
        server_cov_file="${RESULTS_DIR}/python-coverage.cuopt_service"
    fi

    log_info "Starting cuopt_service on 0.0.0.0:${port}; log: ${server_log}"
    if [ -n "${server_cov_file}" ]; then
        log_info "cuopt_service COVERAGE_FILE=${server_cov_file}"
        CUOPT_SERVER_IP=0.0.0.0 \
        CUOPT_SERVER_PORT="${port}" \
        COVERAGE_FILE="${server_cov_file}" \
            python -m cuopt_server.cuopt_service \
                > "${server_log}" 2>&1 &
    else
        CUOPT_SERVER_IP=0.0.0.0 \
        CUOPT_SERVER_PORT="${port}" \
            python -m cuopt_server.cuopt_service \
                > "${server_log}" 2>&1 &
    fi
    local server_pid=$!

    # Always tear the server down on function exit, even on early return /
    # signal. Using a function-scoped trap means we don't disturb any traps
    # the caller may have installed.
    local cleanup="kill -TERM ${server_pid} 2>/dev/null; wait ${server_pid} 2>/dev/null || true"

    # Wait for /cuopt/health to respond. We poll once a second for up to 30
    # iterations so the loop logs progress in CI without spamming.
    local up=0
    local i
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${port}/cuopt/health" >/dev/null 2>&1; then
            log_info "cuopt_service up on :${port} (pid=${server_pid})"
            up=1
            break
        fi
        if ! kill -0 "${server_pid}" 2>/dev/null; then
            log_error "cuopt_service died before /cuopt/health responded; last 30 log lines:"
            tail -n 30 "${server_log}" >&2 || true
            CUOPT_SH_RESULT="ERROR"
            CUOPT_SH_DURATION=$(( $(date +%s) - start ))
            return 2
        fi
        sleep 1
    done
    if [ "${up}" -ne 1 ]; then
        log_error "cuopt_service did not respond on http://127.0.0.1:${port}/cuopt/health within 30s"
        eval "${cleanup}"
        CUOPT_SH_RESULT="ERROR"
        CUOPT_SH_DURATION=$(( $(date +%s) - start ))
        return 2
    fi

    # Run pytest pointed at the freshly-started server. The tests are at
    # python/cuopt_self_hosted/tests/ (NOT cuopt_sh_client/tests/) -- they
    # exercise the high-level self-hosted-client + live-server contract.
    #
    # Coverage (when enabled) targets the cuopt_sh_client package, which is
    # the public Python surface of cuopt_self_hosted.
    local ec=0
    local sh_dir="${ROCOPT_DIR}/python/cuopt_self_hosted"
    if [ ! -d "${sh_dir}/tests" ]; then
        log_error "cuopt_self_hosted tests not found: ${sh_dir}/tests"
        eval "${cleanup}"
        CUOPT_SH_RESULT="ERROR"
        CUOPT_SH_DURATION=$(( $(date +%s) - start ))
        return 2
    fi
    # `--cov=cuopt_sh_client` only resolves to source files that match the
    # path Python actually imported from. With pytest's rootdir at
    # ${sh_dir}, the package gets imported as `${sh_dir}/cuopt_sh_client/...`
    # but coverage.py's source-resolution under that layout records
    # the files in its "known" table without tracing any lines (the
    # exact failure mode the existing wrappers ci/run_cuopt*_pytests.sh
    # avoid by cd'ing into the package itself -- see the leading
    # comment in those wrappers: "essential to cd into <pkg>/<pkg> as
    # pytest-xdist + coverage seem to work only at this directory
    # level"). We mirror that here.
    local sh_pkg_dir="${sh_dir}/cuopt_sh_client"
    local sh_tests_dir="${sh_dir}/tests"
    if [ ! -d "${sh_pkg_dir}" ]; then
        log_error "cuopt_sh_client package dir not found: ${sh_pkg_dir}"
        eval "${cleanup}"
        CUOPT_SH_RESULT="ERROR"
        CUOPT_SH_DURATION=$(( $(date +%s) - start ))
        return 2
    fi

    local pytest_args=("--cache-clear" "--junitxml=${junit}")
    [ -n "${PY_KEYWORD}" ] && pytest_args+=(-k "${PY_KEYWORD}")
    local client_cov_file=""
    if [ "${PYTHON_COVERAGE:-0}" -eq 1 ]; then
        local cov_config=""
        if [ -n "${PYTHON_COVERAGE_CONFIG:-}" ]; then
            cov_config="${PYTHON_COVERAGE_CONFIG}"
        elif [ -f "${ROCOPT_DIR}/.coveragerc" ]; then
            cov_config="${ROCOPT_DIR}/.coveragerc"
        fi
        # Same rationale as the in-container _invoke_pytest_wrapper helper:
        # use a per-suite COVERAGE_FILE, no --cov-append, so pytest-cov's
        # internal combine() can't reach into other suites' files.
        client_cov_file="${RESULTS_DIR}/python-coverage.cuopt_sh_client"
        pytest_args+=(--cov=cuopt_sh_client)
        [ -n "${cov_config}" ] && pytest_args+=(--cov-config="${cov_config}")
    fi
    if [ ${#PYTEST_EXTRA[@]} -gt 0 ]; then
        pytest_args+=("${PYTEST_EXTRA[@]}"); fi

    # We pass the tests dir as an ABSOLUTE path because we cd into the
    # package dir (not the suite parent) so the relative `tests` segment
    # used by the previous version no longer resolves.
    if [ -n "${client_cov_file}" ]; then
        ( cd "${sh_pkg_dir}" \
            && CUOPT_SERVER_PORT="${port}" \
               COVERAGE_FILE="${client_cov_file}" \
               pytest "${pytest_args[@]}" "${sh_tests_dir}" ) || ec=$?
    else
        ( cd "${sh_pkg_dir}" \
            && CUOPT_SERVER_PORT="${port}" \
               pytest "${pytest_args[@]}" "${sh_tests_dir}" ) || ec=$?
    fi

    # Always tear the server down before returning.
    eval "${cleanup}"

    CUOPT_SH_DURATION=$(( $(date +%s) - start ))

    local summary; summary=$(parse_junit_summary "${junit}")
    local _TESTS _FAILURES _ERRORS _SKIPPED
    # shellcheck disable=SC2034
    eval "$(printf '%s' "${summary}" | sed 's/\([a-z]*\)=/_\U\1=/g')"
    CUOPT_SH_TESTS="${_TESTS:-0}"
    CUOPT_SH_FAILS=$(( ${_FAILURES:-0} + ${_ERRORS:-0} ))

    if [ "${ec}" -eq 0 ] && [ "${CUOPT_SH_FAILS}" -eq 0 ]; then
        CUOPT_SH_RESULT="PASS"
        log_info "cuopt_self_hosted PASSED (${CUOPT_SH_TESTS} tests, $(fmt_duration "${CUOPT_SH_DURATION}"))"
        return 0
    else
        CUOPT_SH_RESULT="FAIL"
        log_error "cuopt_self_hosted FAILED (${CUOPT_SH_FAILS}/${CUOPT_SH_TESTS} failed, exit=${ec}, $(fmt_duration "${CUOPT_SH_DURATION}"))"
        return 1
    fi
}

# Dispatcher: run all three Python suites in order, accumulating per-suite
# results into PY_TESTS / PY_FAILS / PY_DURATION for the outer summary line.
# Each sub-runner is allowed to fail independently; we report the worst
# outcome (FAIL beats PASS, ERROR beats FAIL).
run_python_tests() {
    local overall_ec=0
    local rc=0

    run_cuopt_tests             || overall_ec=$?
    run_cuopt_server_tests      || { rc=$?; [ "${rc}" -gt "${overall_ec}" ] && overall_ec=${rc}; }
    run_cuopt_self_hosted_tests || { rc=$?; [ "${rc}" -gt "${overall_ec}" ] && overall_ec=${rc}; }

    PY_TESTS=$(( CUOPT_TESTS + CUOPT_SRV_TESTS + CUOPT_SH_TESTS ))
    PY_FAILS=$(( CUOPT_FAILS + CUOPT_SRV_FAILS + CUOPT_SH_FAILS ))
    PY_DURATION=$(( CUOPT_DURATION + CUOPT_SRV_DURATION + CUOPT_SH_DURATION ))

    # Combined PY_RESULT: any ERROR wins, then FAIL, then PASS. SKIP shouldn't
    # appear here because the dispatcher unconditionally runs all three.
    if [ "${CUOPT_RESULT}" = "ERROR" ] || [ "${CUOPT_SRV_RESULT}" = "ERROR" ] || [ "${CUOPT_SH_RESULT}" = "ERROR" ]; then
        PY_RESULT="ERROR"
    elif [ "${CUOPT_RESULT}" = "FAIL" ] || [ "${CUOPT_SRV_RESULT}" = "FAIL" ] || [ "${CUOPT_SH_RESULT}" = "FAIL" ]; then
        PY_RESULT="FAIL"
    else
        PY_RESULT="PASS"
    fi

    if [ "${PY_RESULT}" = "PASS" ]; then
        log_info "Python suites PASSED (${PY_TESTS} tests total, $(fmt_duration "${PY_DURATION}"))"
        return 0
    else
        log_error "Python suites ${PY_RESULT} (${PY_FAILS}/${PY_TESTS} failed across cuopt/cuopt_server/cuopt_self_hosted)"
        return "${overall_ec}"
    fi
}

# ---------------------------------------------------------------------------
# Drive the suites.  We deliberately do NOT bail out after the first failure;
# running both suites every time gives a fuller picture of breakage.
# ---------------------------------------------------------------------------
EXIT_CODE=0

# Datasets are needed by both the C++ gtests and pytest, so we prepare them
# once up front (before either suite runs).  If dataset prep fails it's a
# hard infrastructure failure: tests would either skip silently or produce
# misleading "fail" results, both of which we want to surface clearly.
prepare_datasets || { EXIT_CODE=2; CPP_RESULT="ERROR"; PY_RESULT="ERROR"; }

if [ "${EXIT_CODE}" -ne 2 ]; then
    if [ "${RUN_CPP}" -eq 1 ]; then
        run_cpp_tests || EXIT_CODE=1
    fi

    if [ "${RUN_PYTHON}" -eq 1 ]; then
        run_python_tests || EXIT_CODE=1
    fi
fi

# An infra-level failure (CPP_RESULT=ERROR) escalates 1 -> 2 since the suite
# couldn't even start.  We treat "all expected suites passed" strictly: if we
# asked for a suite and got SKIP, that's still infra failure.
if [ "${CPP_RESULT}" = "ERROR" ] || [ "${PY_RESULT}" = "ERROR" ]; then
    EXIT_CODE=2
fi

OVERALL_DURATION=$(( $(date +%s) - OVERALL_START ))

log_step "Test run complete (overall: $(fmt_duration "${OVERALL_DURATION}"))"

# Emit the machine-readable summary line on STDOUT (everything else has gone
# to STDERR), AND write it to a file in RESULTS_DIR so the host wrapper can
# read it directly without having to grep the captured stream.
#
# The stream-based path is fragile: pytest's progress output uses \r without
# trailing \n, which can leave the captured stdout with mixed line endings
# that defeat `grep -E '^RESULT '` even though the line is visibly there in
# the terminal.  Writing to a file (which the host bind-mounts as
# ${LOGDIR}/result.txt) bypasses that entirely.  The stream output is kept
# for human-readable terminal display and as a fallback for callers that
# don't bind-mount RESULTS_DIR.
emit_summary \
    "cpp=${CPP_RESULT}" \
    "python=${PY_RESULT}" \
    "cpp_tests=${CPP_TESTS}" \
    "cpp_fail=${CPP_FAILS}" \
    "py_tests=${PY_TESTS}" \
    "py_fail=${PY_FAILS}" \
    "cuopt=${CUOPT_RESULT}" \
    "cuopt_tests=${CUOPT_TESTS}" \
    "cuopt_fail=${CUOPT_FAILS}" \
    "cuopt_server=${CUOPT_SRV_RESULT}" \
    "cuopt_server_tests=${CUOPT_SRV_TESTS}" \
    "cuopt_server_fail=${CUOPT_SRV_FAILS}" \
    "cuopt_self_hosted=${CUOPT_SH_RESULT}" \
    "cuopt_self_hosted_tests=${CUOPT_SH_TESTS}" \
    "cuopt_self_hosted_fail=${CUOPT_SH_FAILS}" \
    "duration=${OVERALL_DURATION}" \
    | tee "${RESULTS_DIR}/result.txt"

exit "${EXIT_CODE}"
