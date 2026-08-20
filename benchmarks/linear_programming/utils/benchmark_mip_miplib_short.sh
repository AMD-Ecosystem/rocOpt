#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Short cross-platform variant (c) 2026
# SPDX-License-Identifier: Apache-2.0
#
# Short MIPLIB 2017 MIP pre-flight benchmark (sibling of
# benchmark_lp_mittelmann_short.sh).
#
# *** NOT FOR PUBLISHED NUMBERS ***
# This is an internal smoke + signal script intended for:
#   - regression detection vs. a previous commit
#   - paired pre-flight comparison of the same build on AMD (ROCm) and
#     NVIDIA (CUDA) before committing to the multi-hour full MIPLIB run
# It uses a curated subset of the MIPLIB 2017 benchmark set, which means
# the numbers it produces are NOT a fair representation of the full suite
# and should not be quoted externally.
#
# Goal: produce a representative MIP result across a slice of the
# MIPLIB 2017 benchmark suite in roughly TIME_BUDGET seconds (default
# 7560s ~= 2.1h) on a single GPU.
#
# How it stays bounded:
#   - Curated subset of MIPLIB 2017 benchmark, sized to N * TIME_LIMIT
#     ~= TIME_BUDGET.
#   - Fixed per-instance time limit (critical for cross-platform fairness
#     -- same cap on both AMD and NVIDIA so wall-time ratio reflects the
#     hardware/solver, not budget bookkeeping).
#   - Each solve is wrapped in `timeout` with a small grace window
#     (TIME_LIMIT + KILL_GRACE seconds, then SIGKILL after KILL_HARD
#     seconds). Necessary because solve_MIP can wedge in HIP shutdown
#     after announcing "Time limit reached", which would otherwise hang
#     the whole run (the solver's own --time-limit cannot rescue us if
#     it hangs *during cleanup*).
#   - Hard-stops the run if cumulative wall time exceeds 1.15 * TIME_BUDGET
#     as a safety net only; this should not normally fire.
#
# Tiers:
#   smoke   ~10 min wall (5 instances, 120s each) -- pipeline sanity check
#   short   ~2 hours wall (default, 21 instances)
#   medium  ~5 hours wall (30 instances, for when you have a half-day)
#
# Environment overrides:
#   TIER          smoke | short | medium     (default: short)
#   TIME_LIMIT    per-instance seconds       (default: derived from tier)
#   TIME_BUDGET   total wall budget seconds  (default: derived from tier)
#   KILL_GRACE    seconds past TIME_LIMIT before SIGTERM        (default: 60)
#   KILL_HARD     seconds past SIGTERM before SIGKILL           (default: 30)
#   HIP_VISIBLE_DEVICES  GPU index to use    (default: 0)
#   OUTPUT_DIR    where to write logs        (default: ./miplib_short_<timestamp>)
#   DATA_DIR      where MPS files live       (default: benchmarks/linear_programming/mip_datasets)
#   SKIP_DOWNLOAD if set, do not download missing instances
#
# Usage:
#   benchmarks/linear_programming/utils/benchmark_mip_miplib_short.sh
#   TIER=smoke  benchmarks/linear_programming/utils/benchmark_mip_miplib_short.sh
#   TIER=medium benchmarks/linear_programming/utils/benchmark_mip_miplib_short.sh

set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CUOPT_HOME="$( cd "$SCRIPT_DIR/../../../" && pwd )"

SOLVE_MIP="${CUOPT_HOME}/cpp/build/solve_MIP"
DATA_DIR="${DATA_DIR:-${CUOPT_HOME}/benchmarks/linear_programming/mip_datasets}"

# MIPLIB 2017 instances live at this URL pattern (same one cuopt CI uses).
MIPLIB_BASE_URL="https://miplib.zib.de/WebData/instances"

# ---------------------------------------------------------------------------
# Curated instance lists. All names must exist as
#   https://miplib.zib.de/WebData/instances/<name>.mps.gz
# (the URL pattern used by datasets/mip/download_miplib_test_dataset.sh).
# ---------------------------------------------------------------------------

# 5 small / fast MIPs -- pipeline smoke test.
SMOKE_INSTANCES=(
    "gen-ip054"
    "enlight_hard"
    "neos5"
    "fiball"
    "tr12-30"
)

# 21 instances, ~2 hour budget. Borrowed wholesale from cuopt's CI MIP
# dataset (datasets/mip/download_miplib_test_dataset.sh) so every entry
# is known to be downloadable. Spans easy/medium difficulty.
SHORT_INSTANCES=(
    "50v-10"
    "fiball"
    "gen-ip054"
    "sct2"
    "uccase9"
    "drayage-25-23"
    "tr12-30"
    "neos-3004026-krka"
    "ns1208400"
    "gmu-35-50"
    "n2seq36q"
    "seymour1"
    "rmatr200-p5"
    "cvs16r128-89"
    "thor50dday"
    "stein9inf"
    "neos5"
    "swath1"
    "enlight_hard"
    "enlight11"
    "supportcase22"
)

# 30 instances, ~5 hour budget. Adds well-known MIPLIB 2017 benchmark
# classics that tend to stress the MIP solver harder (some hit time
# limit; gap then matters more than wall time).
MEDIUM_INSTANCES=(
    "${SHORT_INSTANCES[@]}"
    "mas76"
    "pk1"
    "bnatt500"
    "aflow30a"
    "swath3"
    "glass4"
    "nw04"
    "roll3000"
    "mzzv11"
)

TIER="${TIER:-short}"

case "${TIER}" in
    smoke)
        INSTANCES=("${SMOKE_INSTANCES[@]}")
        DEFAULT_TIME_LIMIT=120
        DEFAULT_TIME_BUDGET=$((${#SMOKE_INSTANCES[@]} * 150))
        ;;
    short)
        INSTANCES=("${SHORT_INSTANCES[@]}")
        DEFAULT_TIME_LIMIT=360
        DEFAULT_TIME_BUDGET=$((${#SHORT_INSTANCES[@]} * 360))
        ;;
    medium)
        INSTANCES=("${MEDIUM_INSTANCES[@]}")
        DEFAULT_TIME_LIMIT=600
        DEFAULT_TIME_BUDGET=$((${#MEDIUM_INSTANCES[@]} * 600))
        ;;
    *)
        echo "ERROR: unknown TIER='${TIER}' (expected: smoke | short | medium)" >&2
        exit 2
        ;;
esac

TIME_LIMIT="${TIME_LIMIT:-${DEFAULT_TIME_LIMIT}}"
TIME_BUDGET="${TIME_BUDGET:-${DEFAULT_TIME_BUDGET}}"
KILL_GRACE="${KILL_GRACE:-60}"
KILL_HARD="${KILL_HARD:-30}"
SOLVE_DEADLINE=$((TIME_LIMIT + KILL_GRACE))

# LIST_ONLY: emit the resolved plan (tier defaults + curated instance list)
# and exit before doing any work. This lets benchmark_multi_gpu.sh reuse this
# file as the single source of truth for the instance list, so the two never
# drift apart. Guarded by an env var so normal runs are unaffected.
if [[ -n "${LIST_ONLY:-}" ]]; then
    echo "TIME_LIMIT=${TIME_LIMIT}"
    echo "TIME_BUDGET=${TIME_BUDGET}"
    echo "KILL_GRACE=${KILL_GRACE}"
    echo "KILL_HARD=${KILL_HARD}"
    printf 'INSTANCE=%s\n' "${INSTANCES[@]}"
    exit 0
fi

export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
# Also export CUDA_VISIBLE_DEVICES for parity with the upstream LP script
# (ROCm's HIP runtime honors HIP_VISIBLE_DEVICES; CUDA_VISIBLE_DEVICES is
# kept set so any cuda-named code paths see the same selection).
export CUDA_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES}"
export CUDA_MODULE_LOADING=EAGER

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Detect platform for the output directory tag and env fingerprint.
if command -v nvidia-smi &>/dev/null; then
    PLATFORM="cuda"
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
elif command -v rocminfo &>/dev/null; then
    PLATFORM="rocm"
    GPU_NAME="$(rocminfo 2>/dev/null | awk -F: '/Marketing Name/ {gsub(/^ +| +$/, "", $2); print $2}' | grep -vi 'EPYC\|Xeon\|Ryzen\|CPU' | head -1)"
    GPU_DRIVER="$(cat /opt/rocm/.info/version 2>/dev/null | head -1)"
else
    PLATFORM="unknown"
    GPU_NAME="unknown"
    GPU_DRIVER="unknown"
fi

OUTPUT_DIR="${OUTPUT_DIR:-${CUOPT_HOME}/benchmarks/miplib_short_${PLATFORM}_${TIMESTAMP}}"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${DATA_DIR}"

SUMMARY_CSV="${OUTPUT_DIR}/summary.csv"
RUN_LOG="${OUTPUT_DIR}/run.log"
ENV_JSON="${OUTPUT_DIR}/env.json"

# Capture environment fingerprint so two runs (e.g. AMD vs NVIDIA) can be
# diff'd later with confidence about what was actually compared.
GIT_SHA="$(git -C "${CUOPT_HOME}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git -C "${CUOPT_HOME}" status --porcelain 2>/dev/null | wc -l)"
cat > "${ENV_JSON}" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "platform": "${PLATFORM}",
  "gpu_name": "${GPU_NAME}",
  "gpu_driver": "${GPU_DRIVER}",
  "git_sha": "${GIT_SHA}",
  "git_dirty_files": ${GIT_DIRTY},
  "benchmark": "miplib_short",
  "tier": "${TIER}",
  "time_limit_per_instance_s": ${TIME_LIMIT},
  "time_budget_s": ${TIME_BUDGET},
  "presolve": 1,
  "n_instances": ${#INSTANCES[@]},
  "visible_device": "${HIP_VISIBLE_DEVICES}",
  "host": "$(hostname)"
}
EOF

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if [[ ! -x "${SOLVE_MIP}" ]]; then
    echo "ERROR: solve_MIP not found or not executable at:"
    echo "  ${SOLVE_MIP}"
    echo
    echo "Rebuild with MIP benchmarks enabled (note the escaped quotes -- build.sh"
    echo "parses --cmake-args via regex and needs the literal quotes in argv):"
    echo "  cd ${CUOPT_HOME} && \\"
    echo "  ./build.sh libcuopt -b -n '--cmake-args=\"-DBUILD_MIP_BENCHMARKS=ON\"'"
    exit 3
fi

# Try to find an instance's MPS file under a few common layouts:
#   <DATA_DIR>/<inst>.mps               (flat -- matches cuopt CI script)
#   <DATA_DIR>/<inst>/<inst>.mps        (per-instance subdir, LP-style)
#   <DATA_DIR>/<inst>                   (raw, no extension)
find_mps_file() {
    local inst="$1"
    local cand
    for cand in \
        "${DATA_DIR}/${inst}.mps" \
        "${DATA_DIR}/${inst}/${inst}.mps" \
        "${DATA_DIR}/${inst}/${inst}" \
        "${DATA_DIR}/${inst}"; do
        if [[ -f "${cand}" ]]; then
            echo "${cand}"
            return 0
        fi
    done
    return 1
}

# Download a single MIPLIB instance if not already present.
download_instance() {
    local inst="$1"
    if find_mps_file "${inst}" >/dev/null; then
        return 0
    fi
    local url="${MIPLIB_BASE_URL}/${inst}.mps.gz"
    local gz="${DATA_DIR}/${inst}.mps.gz"
    echo "  fetching ${url}" | tee -a "${RUN_LOG}"
    if ! wget -4 --tries=3 --continue --progress=dot:mega --retry-connrefused \
              "${url}" -O "${gz}" 2>&1 | tee -a "${RUN_LOG}"; then
        echo "  WARN: failed to download ${url}" | tee -a "${RUN_LOG}"
        rm -f "${gz}"
        return 1
    fi
    gunzip -f "${gz}" || {
        echo "  WARN: failed to gunzip ${gz}" | tee -a "${RUN_LOG}"
        return 1
    }
    return 0
}

if [[ -z "${SKIP_DOWNLOAD:-}" ]]; then
    echo "Downloading any missing MIPLIB instances into ${DATA_DIR}..." \
        | tee -a "${RUN_LOG}"
    for instance in "${INSTANCES[@]}"; do
        download_instance "${instance}" || true
    done
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

{
    echo "=========================================="
    echo "MIPLIB MIP short pre-flight benchmark"
    echo "=========================================="
    echo "  platform        : ${PLATFORM}"
    echo "  gpu             : ${GPU_NAME}"
    echo "  driver          : ${GPU_DRIVER}"
    echo "  git sha         : ${GIT_SHA} (${GIT_DIRTY} dirty files)"
    echo "  tier            : ${TIER}"
    echo "  instances       : ${#INSTANCES[@]}"
    echo "  per-instance    : ${TIME_LIMIT}s  (fixed -- same on every platform for fair compare)"
    echo "  kill grace      : SIGTERM at ${SOLVE_DEADLINE}s, SIGKILL ${KILL_HARD}s later"
    echo "  total budget    : ${TIME_BUDGET}s  ($(awk "BEGIN{printf \"%.2f\", ${TIME_BUDGET}/3600}")h)"
    echo "  worst-case wall : $((${#INSTANCES[@]} * (TIME_LIMIT + KILL_GRACE + KILL_HARD)))s"
    echo "  presolve        : 1 (always on for MIP)"
    echo "  visible device  : ${HIP_VISIBLE_DEVICES}"
    echo "  data dir        : ${DATA_DIR}"
    echo "  output dir      : ${OUTPUT_DIR}"
    echo "  solver binary   : ${SOLVE_MIP}"
    echo "=========================================="
} | tee -a "${RUN_LOG}"

echo "instance,exit_code,wall_seconds,status,objective,solver_time_s,log_file" > "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Run loop
# ---------------------------------------------------------------------------

BENCH_START=$(date +%s)
HARD_STOP=$((BENCH_START + TIME_BUDGET * 115 / 100))   # 1.15x safety margin
COMPLETED=0
SKIPPED=0

# Parse the solver's MIP summary out of a per-instance log. run_mip.cpp
# (see benchmarks/linear_programming/cuopt/run_mip.cpp) logs:
#   "<file>: solution found, obj: <f>"   -- objective is the primal bound
#   "<file>: no solution found"
#   "run_solver <ms>"                    -- total solver time in ms
# We emit "status,objective,solver_time_s" or "NA,NA,NA".
#   status   = FeasibleOrOptimal  (primal bound found)
#            | NoSolution         (solver gave up without a feasible point)
#            | NA                 (couldn't parse anything)
# solve_MIP does not distinguish Optimal vs FeasibleFound on stdout; if you
# need that, parse the per-instance .log directly.
parse_mip_summary() {
    local log="$1"
    if [[ ! -f "${log}" ]]; then
        echo "NA,NA,NA"
        return
    fi
    local status objective solver_time
    local sol_line
    sol_line=$(grep -E ': (solution found|no solution found)' "${log}" | tail -1)
    if [[ -z "${sol_line}" ]]; then
        status="NA"
        objective="NA"
    elif echo "${sol_line}" | grep -q 'no solution found'; then
        status="NoSolution"
        objective="NA"
    else
        status="FeasibleOrOptimal"
        objective=$(echo "${sol_line}" \
            | sed -nE 's/.*solution found,[[:space:]]+obj:[[:space:]]+([-+0-9.eE]+).*/\1/p')
        [[ -z "${objective}" ]] && objective="NA"
    fi
    # run_solver prints duration in ms; convert to seconds.
    local solver_ms
    solver_ms=$(grep -E 'run_solver[[:space:]]+[0-9]+' "${log}" \
                | tail -1 \
                | sed -nE 's/.*run_solver[[:space:]]+([0-9]+).*/\1/p')
    if [[ -n "${solver_ms}" ]]; then
        solver_time=$(awk "BEGIN{printf \"%.3f\", ${solver_ms}/1000.0}")
    else
        solver_time="NA"
    fi
    echo "${status:-NA},${objective:-NA},${solver_time:-NA}"
}

for instance in "${INSTANCES[@]}"; do
    log_file="${OUTPUT_DIR}/${instance}.log"
    mps_file="$(find_mps_file "${instance}" || true)"
    elapsed=$(( $(date +%s) - BENCH_START ))

    if (( $(date +%s) >= HARD_STOP )); then
        echo "[$(date +%H:%M:%S)] HARD STOP: elapsed=${elapsed}s exceeds 1.15x budget; aborting remaining instances" \
            | tee -a "${RUN_LOG}"
        echo "${instance},ABORTED,0,NA,NA,NA,${log_file}" >> "${SUMMARY_CSV}"
        break
    fi

    if [[ -z "${mps_file}" || ! -f "${mps_file}" ]]; then
        echo "[$(date +%H:%M:%S)] SKIP ${instance}: no .mps file under ${DATA_DIR}/" \
            | tee -a "${RUN_LOG}"
        echo "${instance},MISSING,0,NA,NA,NA,${log_file}" >> "${SUMMARY_CSV}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[$(date +%H:%M:%S)] (${COMPLETED}/${#INSTANCES[@]}) solving ${instance} (cap=${TIME_LIMIT}s, kill=${SOLVE_DEADLINE}s+${KILL_HARD}s, elapsed=${elapsed}s)" \
        | tee -a "${RUN_LOG}"

    start=$(date +%s)
    # `timeout` exit codes:
    #   124  : SIGTERM sent at SOLVE_DEADLINE; child exited within KILL_HARD
    #   137  : 128 + SIGKILL(9), i.e. wedged through the grace window
    # Any other non-zero is the solver's own exit code, propagated through.
    timeout --kill-after="${KILL_HARD}s" "${SOLVE_DEADLINE}s" \
        "${SOLVE_MIP}" \
            --path "${mps_file}" \
            --time-limit "${TIME_LIMIT}" \
            > "${log_file}" 2>&1
    exit_code=$?
    end=$(date +%s)
    wall=$((end - start))

    if (( exit_code == 124 || exit_code == 137 )); then
        echo "[$(date +%H:%M:%S)]   WARN: ${instance} hung past ${SOLVE_DEADLINE}s; killed by timeout (rc=${exit_code})" \
            | tee -a "${RUN_LOG}" | tee -a "${log_file}" >/dev/null
    fi

    summary=$(parse_mip_summary "${log_file}")
    echo "${instance},${exit_code},${wall},${summary},${log_file}" >> "${SUMMARY_CSV}"
    echo "[$(date +%H:%M:%S)]   -> exit=${exit_code} wall=${wall}s  ${summary}" | tee -a "${RUN_LOG}"
    COMPLETED=$((COMPLETED + 1))
done

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

TOTAL=$(( $(date +%s) - BENCH_START ))
{
    echo "=========================================="
    echo "Benchmark complete"
    echo "=========================================="
    echo "  completed       : ${COMPLETED}"
    echo "  skipped         : ${SKIPPED}"
    echo "  total wall time : ${TOTAL}s  ($(awk "BEGIN{printf \"%.2f\", ${TOTAL}/3600}")h)"
    echo "  summary         : ${SUMMARY_CSV}"
    echo "  per-instance    : ${OUTPUT_DIR}/<instance>.log"
    echo "=========================================="
} | tee -a "${RUN_LOG}"
