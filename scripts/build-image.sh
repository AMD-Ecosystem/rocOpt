#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Host-side builder for the rocopt docker image.
#
# Wraps `docker build` with sensible defaults for this repo:
#   * Always passes --build-arg GH_USERNAME / GH_TOKEN from the caller's
#     environment (so the in-image clone of the still-private repo works).
#     Falls back to anonymous clone if those vars are unset, which will be
#     correct once the repo is public.
#   * Resolves the remote tip SHA up front and tags the resulting image with
#     BOTH a moving tag (rocopt:<branch>) and a pinned tag (rocopt:<sha7>).
#     Run-tests.sh defaults to the branch tag for ergonomic local use; CI
#     should prefer the SHA tag for reproducibility.
#   * Emits a single machine-readable "BUILD ..." line on stdout at the end.
#
# Quick reference:
#
#   scripts/build-image.sh                       # default branch, gfx942;gfx950
#   scripts/build-image.sh --branch feat/foo
#   scripts/build-image.sh --gpu-arch gfx90a
#   scripts/build-image.sh --gpu-arch 'gfx942;gfx950'   # multi-arch fat binary
#   scripts/build-image.sh --no-cache --tag my-image:latest
#
# Exit codes (consistent with run-tests.sh):
#   0  build succeeded
#   2  infrastructure failure (no docker, no Dockerfile, remote ref missing)
#   3  usage error

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${_SCRIPT_DIR}/lib/common.sh"

# Build-image.sh emits "BUILD k=v ..." rather than the test runner's "RESULT".
SUMMARY_PREFIX="BUILD"

# ---------------------------------------------------------------------------
# Defaults (must stay in sync with the Dockerfile's ARG defaults)
# ---------------------------------------------------------------------------
DEFAULT_BRANCH="awelling/use-open-source-rocm-ds"
# Auto-detect from rocminfo when unset; pass --gpu-arch to override.
DEFAULT_GPU_ARCH=""
DEFAULT_REPO_HOST="github.com/AMD-AIOSS/rocopt.git"
DEFAULT_DOCKERFILE="dockerfile.rocm"
DEFAULT_BUILD_CONTEXT="."
# Two-stage build: compile with the 7.1.1 toolchain (avoids the ROCm 7.2.x
# AMDGPU codegen regression on MI300X, ROCM-21706) and run on the 7.2.3
# runtime.  Keep these in sync with the Dockerfile's ARG defaults.
DEFAULT_ROCM_BUILD_VERSION="7.1.1"
DEFAULT_ROCM_RUNTIME_VERSION="7.2.3"
# Which benchmark binaries to build into the image: none|lp|mip|all.
# `none` matches the prior behaviour (no solve_LP / solve_MIP).
DEFAULT_BENCHMARKS="none"

BRANCH="${DEFAULT_BRANCH}"
GPU_ARCH="${DEFAULT_GPU_ARCH}"
REPO_HOST="${DEFAULT_REPO_HOST}"
DOCKERFILE="${DEFAULT_DOCKERFILE}"
BUILD_CONTEXT="${DEFAULT_BUILD_CONTEXT}"
ROCM_BUILD_VERSION="${DEFAULT_ROCM_BUILD_VERSION}"
ROCM_RUNTIME_VERSION="${DEFAULT_ROCM_RUNTIME_VERSION}"
BENCHMARKS="${DEFAULT_BENCHMARKS}"
NO_CACHE=0
QUIET=0
EXTRA_TAGS=()
EXTRA_BUILD_ARGS=()

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build the rocopt docker image.

Options:
  --branch <name>          Branch to clone inside the image
                           (default: ${DEFAULT_BRANCH})
  --gpu-arch <gfx>         Target GPU arch for build.sh (default: auto-detect
                           from rocminfo; build.sh falls back to gfx90a if none)
  --rocm-build-version <v> ROCm version of the builder stage's compiler
                           toolchain (default: ${DEFAULT_ROCM_BUILD_VERSION})
  --rocm-runtime-version <v>
                           ROCm version of the runtime stage
                           (default: ${DEFAULT_ROCM_RUNTIME_VERSION})
  --benchmarks <what>      Build benchmark binaries into the image:
                           none|lp|mip|all  (default: ${DEFAULT_BENCHMARKS})
                             none = no benchmark binaries
                             lp   = solve_LP  (Mittelmann LP short/full)
                             mip  = solve_MIP (MIPLIB short)
                             all  = both solve_LP and solve_MIP
  --repo-host <host/path>  Override repo location (rare)
                           (default: ${DEFAULT_REPO_HOST})
  --dockerfile <path>      Dockerfile to use (default: ${DEFAULT_DOCKERFILE})
  --context <path>         Build context (default: ${DEFAULT_BUILD_CONTEXT})
  --no-cache               Pass --no-cache to docker build
  --tag <ref>              Apply an additional tag (repeatable)
  --build-arg KEY=VALUE    Forward an extra --build-arg (repeatable)
  --quiet                  Pass --quiet to docker build
  --no-color               Disable ANSI color in this script's output

Environment:
  GH_USERNAME / GH_TOKEN   Forwarded as --build-arg to authenticate the
                           in-image clone (the repo is currently private).
                           Optional once the repo is public.

Output:
  Tags applied to a successful build:
    rocopt:<branch>        Moving tag, points at most recent build of branch
    rocopt:<sha7>          Pinned to the resolved remote-tip SHA

Exit codes: 0=success, 2=infra error, 3=usage error.
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --branch)         BRANCH="$2"; shift 2 ;;
        --gpu-arch)       GPU_ARCH="$2"; shift 2 ;;
        --benchmarks)     BENCHMARKS="$2"; shift 2 ;;
        --rocm-build-version)   ROCM_BUILD_VERSION="$2"; shift 2 ;;
        --rocm-runtime-version) ROCM_RUNTIME_VERSION="$2"; shift 2 ;;
        --repo-host)      REPO_HOST="$2"; shift 2 ;;
        --dockerfile)     DOCKERFILE="$2"; shift 2 ;;
        --context)        BUILD_CONTEXT="$2"; shift 2 ;;
        --no-cache)       NO_CACHE=1; shift ;;
        --tag)            EXTRA_TAGS+=("$2"); shift 2 ;;
        --build-arg)      EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
        --quiet)          QUIET=1; shift ;;
        --no-color)       export ROCOPT_NO_COLOR=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                log_error "unknown arg: $1"; usage >&2; exit 3 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate enum-style options
# ---------------------------------------------------------------------------
case "${BENCHMARKS}" in
    none|lp|mip|all) ;;
    *) log_error "invalid --benchmarks '${BENCHMARKS}' (expected: none|lp|mip|all)"; usage >&2; exit 3 ;;
esac

# Auto-detect GPU arch from rocminfo when --gpu-arch was not supplied.
if [ -z "${GPU_ARCH}" ] && command -v rocminfo >/dev/null 2>&1; then
    GPU_ARCH=$(
        rocminfo | awk '/^[[:space:]]*Name:[[:space:]]+gfx[0-9a-fA-F]+[[:space:]]*$/ {print $2}' \
            | sort -u | paste -sd';'
    )
    if [ -n "${GPU_ARCH}" ]; then
        log_info "auto-detected GPU arch from rocminfo: ${GPU_ARCH}"
    fi
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log_step "Pre-flight checks"
check_docker_daemon

if [ ! -f "${DOCKERFILE}" ]; then
    die "Dockerfile not found: ${DOCKERFILE} (run from the repo root, or pass --dockerfile)"
fi

# Disk space hint (not fatal — different hosts have different docker storage
# locations and `df` of the wrong dir is misleading).  Warn under 30 GB free
# at /var/lib/docker if it exists; otherwise warn under 30 GB at /.
_check_disk_dir="/"
[ -d /var/lib/docker ] && _check_disk_dir="/var/lib/docker"
_avail_kb=$(df -Pk "${_check_disk_dir}" | awk 'NR==2 {print $4}')
_avail_gb=$(( _avail_kb / 1024 / 1024 ))
if [ "${_avail_gb}" -lt 30 ]; then
    log_warn "only ${_avail_gb} GB free at ${_check_disk_dir}; rocopt build needs ~25 GB headroom"
fi

# Cred sanity.
if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
    log_info "GH credentials present (user=${GH_USERNAME}, token=${#GH_TOKEN} chars)"
    log_warn "GH_TOKEN will be embedded in image history.  Do NOT push this image to a public registry."
else
    log_warn "GH_USERNAME / GH_TOKEN not set; falling back to anonymous clone"
    log_warn "  (this is correct once the rocopt repo is public; otherwise the build will fail)"
fi

# ---------------------------------------------------------------------------
# Resolve remote-tip SHA so we can tag the image with it.
# ---------------------------------------------------------------------------
# We use git ls-remote so we don't have to clone the repo on the host.  This
# also serves as a free reachability check for the remote (if ls-remote fails
# the docker build will fail too, but later, after the slow apt/conda layers).
log_step "Resolving remote-tip SHA"
_clone_url="https://${REPO_HOST}"
if [ -n "${GH_USERNAME:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
    _clone_url="https://${GH_USERNAME}:${GH_TOKEN}@${REPO_HOST}"
fi

# git ls-remote prints "<sha>\trefs/heads/<branch>".  We never log the URL
# because it may contain the token.
_full_sha=$(git ls-remote "${_clone_url}" "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}')
if [ -z "${_full_sha}" ]; then
    die "remote branch not found: ${REPO_HOST}@${BRANCH}.  Did you push the branch?"
fi
SHORT_SHA="${_full_sha:0:7}"
log_info "remote ${REPO_HOST}@${BRANCH} -> ${_full_sha}"

# ---------------------------------------------------------------------------
# Compose tags
# ---------------------------------------------------------------------------
# Docker tag grammar is [A-Za-z0-9_.-]{1,128}, must not start with `.` or `-`.
# Branch names routinely contain `/` (e.g. user/feature-foo), so we sanitize
# any disallowed char to `-` before using the branch as a tag.  The git remote
# lookup above still uses the original branch name.
_sanitize_docker_tag() {
    local raw="$1"
    local cleaned
    cleaned=$(printf '%s' "$raw" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g')
    cleaned="${cleaned#[.-]}"
    [ -z "${cleaned}" ] && cleaned="unnamed"
    printf '%s' "${cleaned:0:128}"
}

BRANCH_TAG_SAFE=$(_sanitize_docker_tag "${BRANCH}")
if [ "${BRANCH_TAG_SAFE}" != "${BRANCH}" ]; then
    log_info "branch tag sanitized for docker: ${BRANCH} -> ${BRANCH_TAG_SAFE}"
fi

PRIMARY_TAG="rocopt:${BRANCH_TAG_SAFE}"
SHA_TAG="rocopt:${SHORT_SHA}"
ALL_TAGS=("${PRIMARY_TAG}" "${SHA_TAG}" "${EXTRA_TAGS[@]}")

# ---------------------------------------------------------------------------
# Compose docker build args
# ---------------------------------------------------------------------------
BUILD_ARGS=(
    -f "${DOCKERFILE}"
    --build-arg "ROCOPT_BRANCH=${BRANCH}"
    --build-arg "ROCOPT_REPO_HOST=${REPO_HOST}"
    # Bust the clone layer (and everything downstream) whenever the branch tip
    # moves, so a freshly pushed fix is actually picked up instead of Docker
    # replaying a stale cached checkout.
    --build-arg "ROCOPT_SOURCE_SHA=${_full_sha}"
)
if [ -n "${GPU_ARCH}" ]; then
    BUILD_ARGS+=(--build-arg "ROCOPT_GPU_ARCH=${GPU_ARCH}")
fi
BUILD_ARGS+=(
    --build-arg "ROCM_BUILD_VERSION=${ROCM_BUILD_VERSION}"
    --build-arg "ROCM_RUNTIME_VERSION=${ROCM_RUNTIME_VERSION}"
    --build-arg "ROCOPT_BENCHMARKS=${BENCHMARKS}"
)

# Forward GH creds only when set.  When unset, the Dockerfile's anonymous
# clone path takes over.
if [ -n "${GH_USERNAME:-}" ]; then
    BUILD_ARGS+=(--build-arg "GH_USERNAME=${GH_USERNAME}")
fi
if [ -n "${GH_TOKEN:-}" ]; then
    BUILD_ARGS+=(--build-arg "GH_TOKEN=${GH_TOKEN}")
fi

# Apply all tags.
for t in "${ALL_TAGS[@]}"; do
    BUILD_ARGS+=(-t "$t")
done

[ "${NO_CACHE}" -eq 1 ] && BUILD_ARGS+=(--no-cache)
[ "${QUIET}" -eq 1 ] && BUILD_ARGS+=(--quiet)

if [ ${#EXTRA_BUILD_ARGS[@]} -gt 0 ]; then
    BUILD_ARGS+=("${EXTRA_BUILD_ARGS[@]}")
fi

BUILD_ARGS+=("${BUILD_CONTEXT}")

# ---------------------------------------------------------------------------
# Run docker build
# ---------------------------------------------------------------------------
log_step "Building image"
log_info "branch:   ${BRANCH}"
log_info "sha:      ${_full_sha} (short: ${SHORT_SHA})"
log_info "gpu:      ${GPU_ARCH:-auto (rocminfo/build.sh default)}"
log_info "bench:    ${BENCHMARKS}"
log_info "rocm:     build ${ROCM_BUILD_VERSION} -> runtime ${ROCM_RUNTIME_VERSION}"
log_info "tags:     ${ALL_TAGS[*]}"
log_info "context:  ${BUILD_CONTEXT}"

# We deliberately do NOT use `set +e` here — if docker build fails, propagate
# its non-zero exit immediately.  Docker's own output already explains why.
START=$(date +%s)
"${DOCKER_CMD[@]}" build "${BUILD_ARGS[@]}"
DURATION=$(( $(date +%s) - START ))

# ---------------------------------------------------------------------------
# Post-build: confirm the image exists and emit summary
# ---------------------------------------------------------------------------
IMAGE_ID=$(resolve_image_or_die "${PRIMARY_TAG}")

log_step "Build succeeded in $(fmt_duration "${DURATION}")"
log_info "primary tag: ${PRIMARY_TAG}"
log_info "sha tag:     ${SHA_TAG}"
log_info "image id:    ${IMAGE_ID}"
log_info ""
log_info "Next: run tests against this image"
log_info "  scripts/run-tests.sh --image ${SHA_TAG}"

emit_summary \
    "result=ok" \
    "image=${PRIMARY_TAG}" \
    "sha_tag=${SHA_TAG}" \
    "branch=${BRANCH}" \
    "sha=${_full_sha}" \
    "gpu_arch=${GPU_ARCH}" \
    "benchmarks=${BENCHMARKS}" \
    "rocm_build_version=${ROCM_BUILD_VERSION}" \
    "rocm_runtime_version=${ROCM_RUNTIME_VERSION}" \
    "duration=${DURATION}"
