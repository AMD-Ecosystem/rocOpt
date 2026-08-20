# shellcheck shell=bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for rocopt builder/tester scripts.
#
# This file is meant to be `source`d, not executed.  Functions defined here are
# intentionally POSIX-ish so they work both on the host (Ubuntu 24.04) and
# inside the rocopt container.
#
# Public API (everything else is _underscore_prefixed and private):
#
#   log_info / log_warn / log_error / log_step
#   die <msg>                           - log_error + exit 2 (infra failure)
#   require_cmd <cmd> [<cmd>...]        - die if any command is missing on PATH
#   check_docker_daemon                 - die if docker is unreachable
#   check_gpu_devices                   - die if /dev/kfd or /dev/dri is missing
#   resolve_image_or_die <ref>          - print full image ID, die if not local
#   resolve_short_sha <ref>             - print 7-char SHA for a git ref
#   parse_junit_summary <xml>           - print "tests=N failures=N errors=N"
#   emit_summary <key=val>...           - print a single machine-readable line
#                                         prefixed with "RESULT " or "BUILD "
#                                         depending on $SUMMARY_PREFIX
#
# Exit-code contract (consistent across all scripts):
#   0  success
#   1  test failure (real failures, not infra)
#   2  infrastructure failure (no docker, no GPU, image missing, etc.)
#   3  usage error (bad flags)

# ---------------------------------------------------------------------------
# Colors / TTY detection
# ---------------------------------------------------------------------------
# Disable color when:
#   * stdout is not a TTY (piped, redirected to file, captured by CI)
#   * NO_COLOR is set (https://no-color.org)
#   * --no-color flag was passed (callers set ROCOPT_NO_COLOR=1)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ -z "${ROCOPT_NO_COLOR:-}" ]; then
    _C_RESET=$'\033[0m'
    _C_DIM=$'\033[2m'
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_BLUE=$'\033[34m'
    _C_BOLD=$'\033[1m'
else
    _C_RESET=""
    _C_DIM=""
    _C_RED=""
    _C_GREEN=""
    _C_YELLOW=""
    _C_BLUE=""
    _C_BOLD=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# All log lines go to stderr so stdout stays clean for machine-readable output
# (the final summary line, image IDs, etc.).  Format:
#
#   2026-05-05T07:06:42Z [INFO ] message
#
# This is grep-friendly and CI-friendly (timestamps survive log rotation).

_log() {
    local level="$1"; shift
    local color="$1"; shift
    printf '%s%s [%s%-5s%s] %s\n' \
        "${_C_DIM}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${color}" "${level}" "${_C_RESET}${_C_DIM}" "$*${_C_RESET}" >&2
}

log_info()  { _log "INFO"  "${_C_BLUE}"   "$*"; }
log_warn()  { _log "WARN"  "${_C_YELLOW}" "$*"; }
log_error() { _log "ERROR" "${_C_RED}"    "$*"; }
log_step()  {
    # Visually distinct section marker for major phases.
    printf '\n%s>>> %s%s\n\n' "${_C_BOLD}${_C_GREEN}" "$*" "${_C_RESET}" >&2
}

die() {
    log_error "$*"
    exit 2
}

# ---------------------------------------------------------------------------
# Pre-flight helpers
# ---------------------------------------------------------------------------

# require_cmd cmd1 [cmd2 ...]
#   Verify each command is on PATH; die with a clear message otherwise.
require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Required command(s) not found on PATH: ${missing[*]}"
    fi
}

# check_docker_daemon
#   Verify the docker daemon is reachable.  Tries plain `docker info` first;
#   if that fails with permission denied, retries with sudo (and warns the
#   caller they will need sudo for subsequent commands).
#   Sets DOCKER_CMD globally to either "docker" or "sudo docker".
check_docker_daemon() {
    require_cmd docker

    if docker info >/dev/null 2>&1; then
        DOCKER_CMD=(docker)
        return 0
    fi

    if sudo -n docker info >/dev/null 2>&1; then
        log_warn "docker requires sudo; using 'sudo docker' for subsequent commands"
        log_warn "consider adding your user to the 'docker' group to avoid this"
        DOCKER_CMD=(sudo docker)
        return 0
    fi

    die "docker daemon is unreachable.  Is dockerd running?  Try: sudo systemctl status docker"
}

# check_gpu_devices
#   Verify both /dev/kfd and /dev/dri exist.  These are required for ROCm
#   container access.  Does NOT check whether the user has read access (that
#   is handled by --group-add render/video at run time).
check_gpu_devices() {
    local missing=()
    [ -e /dev/kfd ] || missing+=("/dev/kfd")
    [ -d /dev/dri ] || missing+=("/dev/dri")
    if [ ${#missing[@]} -gt 0 ]; then
        die "GPU device(s) missing: ${missing[*]}.  ROCm kernel driver not loaded?"
    fi
    log_info "GPU devices present: /dev/kfd, /dev/dri"
}

# resolve_image_or_die <image-ref>
#   Print the full image ID for the given reference; die if the image is not
#   present locally.  Uses ${DOCKER_CMD[@]} so it works after sudo escalation.
resolve_image_or_die() {
    local ref="$1"
    local id
    id=$("${DOCKER_CMD[@]}" image inspect --format '{{.Id}}' "$ref" 2>/dev/null) \
        || die "image '${ref}' not found locally.  Build it first with scripts/build-image.sh"
    printf '%s\n' "$id"
}

# resolve_short_sha <ref> [<repo-dir>]
#   Print 7-character SHA for the given git ref, resolved in the repo at
#   <repo-dir> (default: $PWD).  Empty string on failure (does not die — the
#   caller decides whether absence is fatal).
resolve_short_sha() {
    local ref="$1"
    local repo="${2:-${PWD}}"
    git -C "$repo" rev-parse --short=7 "$ref" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# JUnit XML parsing
# ---------------------------------------------------------------------------
# We avoid pulling in xmllint / python just to parse a few attributes from a
# JUnit file; awk on the <testsuite> tag is enough.  Both pytest and
# `ctest --output-junit` emit a top-level <testsuite ... tests="N" failures="N"
# errors="N" skipped="N"> attribute set in the first non-XML-decl line.

# parse_junit_summary <xml-path>
#   Print "tests=N failures=N errors=N skipped=N" for the given XML file.
#   If the file is missing or malformed, all counts are 0 and the function
#   succeeds (the caller decides whether to treat that as a failure).
parse_junit_summary() {
    local xml="$1"
    if [ ! -s "$xml" ]; then
        printf 'tests=0 failures=0 errors=0 skipped=0\n'
        return 0
    fi
    awk '
        /<testsuites?[[:space:]]/ {
            tests = 0; failures = 0; errors = 0; skipped = 0
            for (i = 1; i <= NF; i++) {
                if (match($i, /tests="[0-9]+"/))    { tests    = substr($i, RSTART+7, RLENGTH-8) }
                if (match($i, /failures="[0-9]+"/)) { failures = substr($i, RSTART+10, RLENGTH-11) }
                if (match($i, /errors="[0-9]+"/))   { errors   = substr($i, RSTART+8, RLENGTH-9) }
                if (match($i, /skipped="[0-9]+"/))  { skipped  = substr($i, RSTART+9, RLENGTH-10) }
            }
            printf "tests=%d failures=%d errors=%d skipped=%d\n", tests, failures, errors, skipped
            exit
        }
    ' "$xml"
}

# ---------------------------------------------------------------------------
# Machine-readable summary
# ---------------------------------------------------------------------------
# emit_summary key1=val1 key2=val2 ...
#   Print a single line to STDOUT (not stderr) of the form:
#       <PREFIX> key1=val1 key2=val2 ...
#   Where <PREFIX> defaults to "RESULT" but callers can set SUMMARY_PREFIX to
#   "BUILD" for build-image.sh.  Designed to be grep'd by CI.
emit_summary() {
    local prefix="${SUMMARY_PREFIX:-RESULT}"
    printf '%s' "$prefix"
    for kv in "$@"; do
        printf ' %s' "$kv"
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# fmt_duration <seconds>
#   Print "Hh Mm Ss" or "Mm Ss" or "Ss" depending on magnitude.
fmt_duration() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then
        printf '%dh %dm %ds\n' $((s/3600)) $(((s%3600)/60)) $((s%60))
    elif [ "$s" -ge 60 ]; then
        printf '%dm %ds\n' $((s/60)) $((s%60))
    else
        printf '%ds\n' "$s"
    fi
}

# Mark this file as sourced so callers can guard against double-sourcing.
# Exported so external callers can detect it from sub-shells if needed.
export ROCOPT_COMMON_SH_SOURCED=1
