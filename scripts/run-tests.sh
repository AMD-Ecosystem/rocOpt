#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Host-side test runner for the rocopt docker image.
#
# Wraps `docker run` with the right device flags, bind-mounts a host log dir
# for JUnit XML, and delegates to scripts/lib/in-container-tests.sh inside
# the container.  Designed for both local developer use and CI.
#
# Quick reference:
#
#   scripts/run-tests.sh                       # all tests, latest local image
#   scripts/run-tests.sh --image rocopt:abc123 # specific image
#   scripts/run-tests.sh --python -k routing   # pytest -k routing only
#   scripts/run-tests.sh --cpp --ctest-filter "Mps.*"
#   scripts/run-tests.sh --rebuild             # incremental rebuild + test
#   scripts/run-tests.sh --logdir ./test-logs/$(date +%s)
#
# Exit codes (consistent across all scripts in this directory):
#   0  success
#   1  test failures
#   2  infrastructure failure (no docker, no GPU, image missing, etc.)
#   3  usage error

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${_SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IMAGE=""                                    # default resolved below
SUITE_FLAG=""                               # forwarded to in-container-tests.sh
PY_KEYWORD=""
CTEST_FILTER=""
LOGDIR=""                                   # default: ./test-logs/<timestamp>
REBUILD=0
DETACH_KEEP=0                               # if set, leave the container alive on failure
SKIP_DATASETS=0
EXTRA_PYTEST_ARGS=()
HOST_REPO_DIR="${HOST_REPO_DIR:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"

# Defaults that match the Dockerfile.
DEFAULT_BRANCH_TAG="rocopt:amd-integration"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [-- <extra pytest args>]

Run rocopt's C++ and/or Python test suites in a docker container.

Suite selection:
  --cpp                   C++ gtests only
  --python                pytest only
  --all                   Both (default)

Filters:
  --ctest-filter <regex>  Restrict ctest / gtest names by regex
  -k <expr>               Forwarded to pytest -k

Image / iteration:
  --image <ref>           Image to run (default: ${DEFAULT_BRANCH_TAG})
  --rebuild               Bind-mount host repo, rerun ./build.sh inside the
                          container (incremental), then run tests.  Skips the
                          full image rebuild.  Useful inner-loop for code
                          changes when the image's conda env is already good.
  --keep-on-fail          Leave the container alive on test failure for
                          post-mortem (\`docker exec\` into it).  Default: --rm.

Datasets:
  --skip-datasets         Skip the dataset download phase (assume they are
                          pre-staged in the image at /rocopt-release/datasets/)

Output:
  --logdir <path>         Where to put JUnit XML on the host
                          (default: ./test-logs/<utc-timestamp>)
  --no-color              Disable ANSI color in this script's output

Anything after a literal '--' is forwarded verbatim to pytest.

Exit codes: 0=success, 1=test failures, 2=infra error, 3=usage error.
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --cpp)              SUITE_FLAG="--cpp"; shift ;;
        --python)           SUITE_FLAG="--python"; shift ;;
        --all)               SUITE_FLAG="--all"; shift ;;
        --ctest-filter)     CTEST_FILTER="$2"; shift 2 ;;
        -k)                 PY_KEYWORD="$2"; shift 2 ;;
        --image)            IMAGE="$2"; shift 2 ;;
        --rebuild)          REBUILD=1; shift ;;
        --keep-on-fail)     DETACH_KEEP=1; shift ;;
        --skip-datasets)    SKIP_DATASETS=1; shift ;;
        --logdir)           LOGDIR="$2"; shift 2 ;;
        --no-color)         export ROCOPT_NO_COLOR=1; shift ;;
        --)                 shift; EXTRA_PYTEST_ARGS=("$@"); break ;;
        -h|--help)          usage; exit 0 ;;
        *)                  log_error "unknown arg: $1"; usage >&2; exit 3 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log_step "Pre-flight checks"
check_docker_daemon
check_gpu_devices

if [ -z "${IMAGE}" ]; then
    IMAGE="${DEFAULT_BRANCH_TAG}"
fi
IMAGE_ID=$(resolve_image_or_die "${IMAGE}")
log_info "Image: ${IMAGE} (${IMAGE_ID:7:12})"

# Default LOGDIR is timestamped under the current dir so multiple runs
# don't clobber each other.  Resolve to absolute so docker can mount it.
if [ -z "${LOGDIR}" ]; then
    LOGDIR="${PWD}/test-logs/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "${LOGDIR}"
LOGDIR=$(cd "${LOGDIR}" && pwd)
log_info "Test results will land in: ${LOGDIR}"

# ---------------------------------------------------------------------------
# Build the docker run command
# ---------------------------------------------------------------------------
DOCKER_ARGS=(
    run
    --device=/dev/kfd
    --device=/dev/dri
    --group-add=video
    --group-add=render
    --ipc=host
    --shm-size=8G
    --security-opt seccomp=unconfined
    --cap-add=SYS_PTRACE
    -v "${LOGDIR}:/rocopt-release/test-results"
    -e "ROCOPT_NO_COLOR=${ROCOPT_NO_COLOR:-}"
)

# --rm by default; --keep-on-fail removes it but keeps detach behavior.
# Implementation: with --keep-on-fail we omit --rm and stop+commit on failure
# so a developer can `docker start -ai` it later.  Simpler: just omit --rm.
if [ "${DETACH_KEEP}" -eq 0 ]; then
    DOCKER_ARGS+=(--rm)
fi

# Optional --rebuild: bind-mount the host repo over /rocopt-release so the
# source visible inside the container is exactly what's on the host.  Then
# the entrypoint runs ./build.sh first, then the tests.
if [ "${REBUILD}" -eq 1 ]; then
    log_warn "REBUILD mode: bind-mounting ${HOST_REPO_DIR} -> /rocopt-release"
    log_warn "  (host source overrides what's baked into the image)"
    DOCKER_ARGS+=(-v "${HOST_REPO_DIR}:/rocopt-release")
else
    # Always bind-mount the host scripts/ over the image's scripts/.  This
    # lets the orchestration code (in-container-tests.sh and helpers) be
    # iterated on without rebuilding the 26 GB image, AND it means the
    # script works even against images whose underlying clone predates the
    # scripts/ directory in the rocopt repo (which is the case until the
    # scripts are committed and pushed to origin/<branch>).
    if [ -d "${HOST_REPO_DIR}/scripts" ]; then
        log_info "Mounting host scripts/ -> /rocopt-release/scripts/ (read-only)"
        DOCKER_ARGS+=(-v "${HOST_REPO_DIR}/scripts:/rocopt-release/scripts:ro")
    else
        log_warn "host ${HOST_REPO_DIR}/scripts not found; relying on image's baked-in copy"
    fi
fi

DOCKER_ARGS+=("${IMAGE}")

# ---------------------------------------------------------------------------
# Container entrypoint
# ---------------------------------------------------------------------------
# We run our own bash invocation rather than relying on whatever ENTRYPOINT
# the image has, so the script behavior is identical with or without --rebuild
# and across image variants.
#
# The script we run inside is /rocopt-release/scripts/lib/in-container-tests.sh
# — present in the image when built normally, and present via the bind-mount
# in --rebuild mode.

# Compose the in-container command line.
CMD='set -e; '
if [ "${REBUILD}" -eq 1 ]; then
    # Activate conda, run an incremental build, then continue.  Detect the
    # HIP target from rocminfo (same path as the Dockerfiles) so build.sh picks
    # the active GPU instead of falling back to gfx90a.
    #
    # The single-quoted block here is intentional: ${CONDA_DIR}, $PATH,
    # $(nproc), etc. must be expanded INSIDE the container at runtime,
    # not on the host before docker run.  shellcheck's SC2016 warning
    # about non-expansion is exactly the behavior we want.
    # shellcheck disable=SC2016
    CMD+='
        source ${CONDA_DIR:-/root/miniforge3}/bin/activate cuopt_dev;
        source /rocopt-release/scripts/detect_rocopt_gpu_arch.sh 2>/dev/null || true;
        export PARALLEL_LEVEL=$(nproc);
        cd /rocopt-release;
        echo ">>> Incremental rebuild via build.sh ...";
        ./build.sh --use-rocm libmps_parser libcuopt cuopt cuopt_mps_parser cuopt_server cuopt_sh_client;
    '
fi

# Forward filters and suite selection to in-container-tests.sh.  We use
# printf %q to safely pass user-provided regex/keyword strings through the
# bash -c boundary (CTEST_FILTER could contain spaces or quotes).
CMD+='bash /rocopt-release/scripts/lib/in-container-tests.sh'
[ -n "${SUITE_FLAG}" ]    && CMD+=" ${SUITE_FLAG}"
[ "${SKIP_DATASETS}" -eq 1 ] && CMD+=" --skip-datasets"
[ -n "${CTEST_FILTER}" ] && CMD+=" --ctest-filter $(printf '%q' "${CTEST_FILTER}")"
[ -n "${PY_KEYWORD}" ]   && CMD+=" -k $(printf '%q' "${PY_KEYWORD}")"
if [ ${#EXTRA_PYTEST_ARGS[@]} -gt 0 ]; then
    CMD+=" --"
    for a in "${EXTRA_PYTEST_ARGS[@]}"; do
        CMD+=" $(printf '%q' "$a")"
    done
fi

DOCKER_ARGS+=(bash -c "${CMD}")

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
log_step "Launching container"
log_info "command: ${DOCKER_CMD[*]} ${DOCKER_ARGS[*]:0:6} ... ${IMAGE} bash -c '...'"

START=$(date +%s)

# We tee stdout to capture the RESULT line for the host-side summary.  The
# in-container script writes everything else to stderr, so this tee only
# catches the summary line (and any stray stdout from --rebuild's build).
RESULT_LINE=""
RUN_OUT=$(mktemp)
trap 'rm -f "${RUN_OUT}"' EXIT

set +e
"${DOCKER_CMD[@]}" "${DOCKER_ARGS[@]}" | tee "${RUN_OUT}"
EXIT_CODE=${PIPESTATUS[0]}
set -e

DURATION=$(( $(date +%s) - START ))

# Pull the RESULT line out.  Prefer the artifact file written by the
# in-container driver (robust against any stream weirdness — pytest's \r
# progress output can corrupt the captured stdout enough that grep misses
# the line).  Fall back to grep on the captured stream if the file isn't
# present (older images, or someone running the driver standalone without a
# RESULTS_DIR bind-mount).
RESULT_FILE="${LOGDIR}/result.txt"
RESULT_LINE=""
if [ -s "${RESULT_FILE}" ]; then
    RESULT_LINE=$(grep -E '^RESULT ' "${RESULT_FILE}" | tail -1 || true)
fi
if [ -z "${RESULT_LINE}" ]; then
    RESULT_LINE=$(grep -aE '^RESULT ' "${RUN_OUT}" | tail -1 || true)
fi

# ---------------------------------------------------------------------------
# Host-side summary
# ---------------------------------------------------------------------------
log_step "Summary"

if [ -n "${RESULT_LINE}" ]; then
    # Pretty-print the parsed result line as a small table.  We just split on
    # spaces; the in-container script always emits key=value tokens.
    printf '\n'
    printf '  %-14s %s\n' "image:"    "${IMAGE} (${IMAGE_ID:7:12})"
    printf '  %-14s %s\n' "logdir:"   "${LOGDIR}"
    printf '  %-14s %s\n' "duration:" "$(fmt_duration "${DURATION}")"
    printf '  %s\n' "------------------------------------------------"
    for kv in ${RESULT_LINE#RESULT }; do
        k="${kv%%=*}"; v="${kv#*=}"
        printf '  %-14s %s\n' "${k}:" "${v}"
    done
    printf '\n'
    printf '%s\n' "${RESULT_LINE}"
else
    log_warn "no RESULT line found in container output (test driver may have crashed)"
    emit_summary "status=ERROR" "duration=${DURATION}" "exit=${EXIT_CODE}"
fi

exit "${EXIT_CODE}"
