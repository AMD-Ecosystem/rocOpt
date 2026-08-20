#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# One-shot CI driver: cold-build the image, then run the full test suite
# against the SHA-pinned tag.  Designed to be invoked by:
#   * a developer doing a "from-scratch like CI" run on a workstation, or
#   * an actual CI worker (GitHub Actions, etc.) — no interactive prompts,
#     strict exit codes, structured artifacts on disk.
#
# Outputs (one timestamped directory per invocation):
#
#   ~/rocopt-working/ci-runs/<utc-timestamp>/
#   ├── build.log                # full docker-build output (stdout+stderr)
#   ├── test.log                 # full test-runner output (stdout+stderr)
#   ├── summary.txt              # BUILD/RESULT lines + computed exit code
#   └── test-results/            # JUnit XML for ctest + pytest
#       ├── ctest.xml
#       └── pytest.xml
#
# Exit codes:
#   0  build + tests both succeeded
#   1  build succeeded, tests had failures
#   2  infrastructure failure (build error, image missing, GPU missing, etc.)
#   3  usage error
#
# Required environment:
#   GH_USERNAME / GH_TOKEN   (until rocopt is open-sourced; anonymous clone
#                            otherwise — already handled by build-image.sh).

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${_SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults / arg parse
# ---------------------------------------------------------------------------
USE_NO_CACHE=1                     # CI default: cold build
USE_NO_COLOR=1                     # CI default: no ANSI in logs
EXTRA_BUILD_FLAGS=()
EXTRA_TEST_FLAGS=()
RUN_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Run the full CI pipeline: cold-build the rocopt image, then run all tests.

Options:
  --warm-cache             Allow docker layer cache (default: --no-cache)
  --color                  Keep ANSI color in logs (default: --no-color)
  --rundir <path>          Output dir (default: ./ci-runs/<utc-timestamp>)
  --build-arg <flag>       Extra arg forwarded to build-image.sh (repeatable)
  --test-arg <flag>        Extra arg forwarded to run-tests.sh (repeatable)
  -h, --help               Show this help

Environment:
  GH_USERNAME / GH_TOKEN   Forwarded to build-image.sh for the in-image clone.

Exit: 0=success, 1=test failures, 2=infra error, 3=usage error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --warm-cache)   USE_NO_CACHE=0; shift ;;
        --color)        USE_NO_COLOR=0; shift ;;
        --rundir)       RUN_DIR="$2"; shift 2 ;;
        --build-arg)    EXTRA_BUILD_FLAGS+=("$2"); shift 2 ;;
        --test-arg)     EXTRA_TEST_FLAGS+=("$2"); shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_error "unknown arg: $1"; usage >&2; exit 3 ;;
    esac
done

[ "${USE_NO_COLOR}" -eq 1 ] && export ROCOPT_NO_COLOR=1

# ---------------------------------------------------------------------------
# Allocate run directory (timestamped, never reused)
# ---------------------------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ)
if [ -z "${RUN_DIR}" ]; then
    RUN_DIR="${_REPO_DIR}/ci-runs/${TS}"
fi
mkdir -p "${RUN_DIR}/test-results"
RUN_DIR=$(cd "${RUN_DIR}" && pwd)

BUILD_LOG="${RUN_DIR}/build.log"
TEST_LOG="${RUN_DIR}/test.log"
SUMMARY="${RUN_DIR}/summary.txt"

log_step "CI run starting (output: ${RUN_DIR})"
log_info "host:      $(hostname)"
log_info "user:      $(id -un)"
log_info "timestamp: ${TS}"
log_info "repo dir:  ${_REPO_DIR}"

# Sanity: warn loudly if creds missing (build will fail later anyway, but
# this gives a clear message in the FIRST log line rather than buried 30
# minutes deep in apt-fetch).
if [ -z "${GH_USERNAME:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
    log_warn "GH_USERNAME / GH_TOKEN are NOT set."
    log_warn "If the rocopt repo is still private the in-image clone will fail."
fi

# ---------------------------------------------------------------------------
# Phase 1: build
# ---------------------------------------------------------------------------
log_step "Phase 1/2: build-image.sh"
BUILD_FLAGS=()
[ "${USE_NO_CACHE}" -eq 1 ] && BUILD_FLAGS+=(--no-cache)
[ "${USE_NO_COLOR}" -eq 1 ] && BUILD_FLAGS+=(--no-color)
if [ ${#EXTRA_BUILD_FLAGS[@]} -gt 0 ]; then
    BUILD_FLAGS+=("${EXTRA_BUILD_FLAGS[@]}")
fi

log_info "command: scripts/build-image.sh ${BUILD_FLAGS[*]}"
log_info "logging to: ${BUILD_LOG}"

# We tee to BOTH the log file AND the terminal so the operator can watch
# progress, but PIPESTATUS preserves the real exit code from the build.
# Run from the repo root so the build context (.) is correct.
BUILD_START=$(date +%s)
(
    cd "${_REPO_DIR}" && \
    "${_SCRIPT_DIR}/build-image.sh" "${BUILD_FLAGS[@]}"
) 2>&1 | tee "${BUILD_LOG}"
BUILD_EXIT=${PIPESTATUS[0]}
BUILD_DURATION=$(( $(date +%s) - BUILD_START ))

log_info "build exited ${BUILD_EXIT} after $(fmt_duration "${BUILD_DURATION}")"

if [ "${BUILD_EXIT}" -ne 0 ]; then
    log_error "build failed (exit ${BUILD_EXIT}); skipping tests"
    {
        echo "BUILD result=fail exit=${BUILD_EXIT} duration=${BUILD_DURATION}"
        echo "RESULT skipped=true reason=build_failed"
        echo "CI exit=2"
    } > "${SUMMARY}"
    exit 2
fi

# Extract the SHA-pinned tag emitted by build-image.sh.  We look for the
# stable "BUILD ..." summary line and pull out sha_tag=...  Falls back to the
# branch tag if not found (shouldn't happen, but better than crashing).
BUILD_LINE=$(grep -E '^BUILD ' "${BUILD_LOG}" | tail -1 || true)
SHA_TAG=$(printf '%s\n' "${BUILD_LINE}" \
    | tr ' ' '\n' \
    | sed -n 's/^sha_tag=//p' \
    | head -1)
PRIMARY_TAG=$(printf '%s\n' "${BUILD_LINE}" \
    | tr ' ' '\n' \
    | sed -n 's/^image=//p' \
    | head -1)
TEST_TAG="${SHA_TAG:-${PRIMARY_TAG:-rocopt:amd-integration}}"

log_info "tagged: ${PRIMARY_TAG} + ${SHA_TAG}"
log_info "tests will use SHA-pinned tag: ${TEST_TAG}"

# ---------------------------------------------------------------------------
# Phase 2: test
# ---------------------------------------------------------------------------
log_step "Phase 2/2: run-tests.sh"
TEST_FLAGS=(--image "${TEST_TAG}" --logdir "${RUN_DIR}/test-results")
[ "${USE_NO_COLOR}" -eq 1 ] && TEST_FLAGS+=(--no-color)
if [ ${#EXTRA_TEST_FLAGS[@]} -gt 0 ]; then
    TEST_FLAGS+=("${EXTRA_TEST_FLAGS[@]}")
fi

log_info "command: scripts/run-tests.sh ${TEST_FLAGS[*]}"
log_info "logging to: ${TEST_LOG}"

TEST_START=$(date +%s)
(
    cd "${_REPO_DIR}" && \
    "${_SCRIPT_DIR}/run-tests.sh" "${TEST_FLAGS[@]}"
) 2>&1 | tee "${TEST_LOG}"
TEST_EXIT=${PIPESTATUS[0]}
TEST_DURATION=$(( $(date +%s) - TEST_START ))

log_info "tests exited ${TEST_EXIT} after $(fmt_duration "${TEST_DURATION}")"

# ---------------------------------------------------------------------------
# Final summary (machine-parseable; CI greps for these lines)
# ---------------------------------------------------------------------------
RESULT_LINE=$(grep -E '^RESULT ' "${TEST_LOG}" | tail -1 || true)

# Compute final CI exit code:
#   * tests had structured failures   -> 1
#   * tests crashed (no RESULT line)  -> 2
#   * tests passed                    -> 0
case "${TEST_EXIT}" in
    0) FINAL_EXIT=0 ;;
    1) FINAL_EXIT=1 ;;
    *) FINAL_EXIT=2 ;;
esac
[ -z "${RESULT_LINE}" ] && [ "${FINAL_EXIT}" -eq 0 ] && FINAL_EXIT=2

{
    echo "BUILD result=ok image=${PRIMARY_TAG} sha_tag=${SHA_TAG} duration=${BUILD_DURATION}"
    if [ -n "${RESULT_LINE}" ]; then
        echo "${RESULT_LINE}"
    else
        echo "RESULT status=ERROR exit=${TEST_EXIT} duration=${TEST_DURATION}"
    fi
    echo "CI exit=${FINAL_EXIT} build_duration=${BUILD_DURATION} test_duration=${TEST_DURATION} total_duration=$(( BUILD_DURATION + TEST_DURATION ))"
} > "${SUMMARY}"

log_step "CI run complete (total: $(fmt_duration $(( BUILD_DURATION + TEST_DURATION ))))"
printf '\n=== summary ===\n'
cat "${SUMMARY}"
printf '\nartifacts: %s\n' "${RUN_DIR}"

exit "${FINAL_EXIT}"
