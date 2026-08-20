#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Short cross-platform variant (c) 2026
# SPDX-License-Identifier: Apache-2.0
#
# Short Mittelmann LP pre-flight benchmark.
#
# *** NOT FOR PUBLISHED NUMBERS ***
# This is an internal smoke + signal script intended for:
#   - regression detection vs. a previous commit
#   - paired pre-flight comparison of the same build on AMD (ROCm) and
#     NVIDIA (CUDA) before committing to the multi-hour full Mittelmann
#     overnight run (benchmark_lp_mittelmann.sh)
# It uses a curated subset of LPFeasibleMittelmannSet, which means the
# numbers it produces are NOT a fair representation of the full suite and
# should not be quoted externally.
#
# Goal: produce a representative PDLP result across a slice of the
# Mittelmann LP suite in roughly TIME_BUDGET seconds (default 7200s = 2h)
# on a single GPU.
#
# How it stays bounded:
#   - Curated subset of LPFeasibleMittelmannSet, sized to N * TIME_LIMIT
#     ~= TIME_BUDGET.
#   - Fixed per-instance time limit (critical for cross-platform fairness
#     -- same cap on both AMD and NVIDIA so wall-time ratio reflects the
#     hardware/solver, not budget bookkeeping).
#   - Hard-stops the run if cumulative wall time exceeds 1.15 * TIME_BUDGET
#     as a safety net only; this should not normally fire.
#
# Tiers:
#   smoke   ~10 min wall (5 instances, 120s each) -- pipeline sanity check
#   short   ~2 hours wall (default, 20 instances)
#   medium  ~4 hours wall (30 instances, for when you have a half-day)
#
# Environment overrides:
#   TIER          smoke | short | medium     (default: short)
#   TIME_LIMIT    per-instance seconds       (default: derived from tier)
#   TIME_BUDGET   total wall budget seconds  (default: derived from tier)
#   METHOD        0=Concurrent 1=PDLP 2=DualSimplex 3=Barrier (default: 1)
#   PRESOLVE      0|1 enable third-party presolve (default: 0 for PDLP, 1 for DualSimplex)
#   HIP_VISIBLE_DEVICES  GPU index to use    (default: 0)
#   OUTPUT_DIR    where to write logs        (default: ./mittelmann_short_<timestamp>)
#   DATA_DIR      where MPS files live       (default: benchmarks/.../datasets)
#   SKIP_DOWNLOAD if set, do not invoke get_datasets.py
#
# Usage:
#   benchmarks/linear_programming/utils/benchmark_lp_mittelmann_short.sh
#   TIER=smoke benchmarks/linear_programming/utils/benchmark_lp_mittelmann_short.sh
#   TIER=medium METHOD=1 \
#     benchmarks/linear_programming/utils/benchmark_lp_mittelmann_short.sh

set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CUOPT_HOME="$( cd "$SCRIPT_DIR/../../../" && pwd )"

SOLVE_LP="${CUOPT_HOME}/cpp/build/solve_LP"
GET_DATASETS="${CUOPT_HOME}/benchmarks/linear_programming/utils/get_datasets.py"
DATA_DIR="${DATA_DIR:-${CUOPT_HOME}/benchmarks/linear_programming/datasets}"

# ---------------------------------------------------------------------------
# Curated instance lists. All names must exist in LPFeasibleMittelmannSet
# (see get_datasets.py) so the download step picks them up automatically.
# ---------------------------------------------------------------------------

# 5 small / fast instances -- pipeline smoke test.
SMOKE_INSTANCES=(
    "ex10"
    "graph40-40"
    "qap15"
    "nug08-3rd"
    "savsched1"
)

# 20 instances, ~2 hour budget. Mix of fast PDLP-friendly LPs plus a few
# medium-difficulty problems so the result is representative of the suite.
SHORT_INSTANCES=(
    "ex10"
    "datt256_lp"
    "graph40-40"
    "nug08-3rd"
    "qap15"
    "savsched1"
    "scpm1"
    "a2864"
    "fome13"
    "rmine15"
    "woodlands09"
    "supportcase10"
    "rail4284"
    "stp3d"
    "neos-5052403-cygnet"
    "pds-100"
    "square41"
    "Linf_520c"
    "neos"
    "neos3"
)

# 30 instances, ~4 hour budget. Adds harder ones (cont*, s*, thk_*, dlr*).
MEDIUM_INSTANCES=(
    "${SHORT_INSTANCES[@]}"
    "neos-3025225"
    "neos-5251015"
    "ns1687037"
    "ns1688926"
    "stat96v2"
    "set-cover-model"
    "s250r10"
    "thk_48"
    "L1_sixm250obs"
    "shs1023"
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
        DEFAULT_TIME_BUDGET=7200
        ;;
    medium)
        INSTANCES=("${MEDIUM_INSTANCES[@]}")
        DEFAULT_TIME_LIMIT=480
        DEFAULT_TIME_BUDGET=14400
        ;;
    *)
        echo "ERROR: unknown TIER='${TIER}' (expected: smoke | short | medium)" >&2
        exit 2
        ;;
esac

TIME_LIMIT="${TIME_LIMIT:-${DEFAULT_TIME_LIMIT}}"
TIME_BUDGET="${TIME_BUDGET:-${DEFAULT_TIME_BUDGET}}"
METHOD="${METHOD:-1}"

# Presolve default: off for PDLP (which has its own preprocessing), on for
# DualSimplex / Barrier where third-party presolve makes a large difference.
if [[ -z "${PRESOLVE:-}" ]]; then
    case "${METHOD}" in
        2|3) PRESOLVE=1 ;;
        *)   PRESOLVE=0 ;;
    esac
fi
# LIST_ONLY: emit the resolved plan (tier defaults + curated instance list)
# and exit before doing any work. This lets benchmark_multi_gpu.sh reuse this
# file as the single source of truth for the instance list, so the two never
# drift apart. Guarded by an env var so normal runs are unaffected.
if [[ -n "${LIST_ONLY:-}" ]]; then
    echo "TIME_LIMIT=${TIME_LIMIT}"
    echo "TIME_BUDGET=${TIME_BUDGET}"
    echo "METHOD=${METHOD}"
    echo "PRESOLVE=${PRESOLVE}"
    printf 'INSTANCE=%s\n' "${INSTANCES[@]}"
    exit 0
fi

export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
# Also export CUDA_VISIBLE_DEVICES for parity with the upstream script
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

OUTPUT_DIR="${OUTPUT_DIR:-${CUOPT_HOME}/benchmarks/mittelmann_short_${PLATFORM}_${TIMESTAMP}}"
mkdir -p "${OUTPUT_DIR}"

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
  "tier": "${TIER}",
  "time_limit_per_instance_s": ${TIME_LIMIT},
  "time_budget_s": ${TIME_BUDGET},
  "method": ${METHOD},
  "presolve": ${PRESOLVE},
  "n_instances": ${#INSTANCES[@]},
  "visible_device": "${HIP_VISIBLE_DEVICES}",
  "host": "$(hostname)"
}
EOF

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if [[ ! -x "${SOLVE_LP}" ]]; then
    echo "ERROR: solve_LP not found or not executable at:"
    echo "  ${SOLVE_LP}"
    echo
    echo "Rebuild with LP benchmarks enabled:"
    echo "  cd ${CUOPT_HOME} && ./build.sh libcuopt -b -n"
    exit 3
fi

if [[ -z "${SKIP_DOWNLOAD:-}" ]]; then
    echo "Downloading any missing Mittelmann LP instances into ${DATA_DIR}..."
    python3 "${GET_DATASETS}" -LPfeasible \
        -instance-download-path "${DATA_DIR}" \
        2>&1 | tee -a "${RUN_LOG}"
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

{
    echo "=========================================="
    echo "Mittelmann LP short pre-flight benchmark"
    echo "=========================================="
    echo "  platform        : ${PLATFORM}"
    echo "  gpu             : ${GPU_NAME}"
    echo "  driver          : ${GPU_DRIVER}"
    echo "  git sha         : ${GIT_SHA} (${GIT_DIRTY} dirty files)"
    echo "  tier            : ${TIER}"
    echo "  instances       : ${#INSTANCES[@]}"
    echo "  per-instance    : ${TIME_LIMIT}s  (fixed -- same on every platform for fair compare)"
    echo "  total budget    : ${TIME_BUDGET}s  ($(awk "BEGIN{printf \"%.2f\", ${TIME_BUDGET}/3600}")h)"
    echo "  worst-case wall : $((${#INSTANCES[@]} * TIME_LIMIT))s"
    echo "  method          : ${METHOD}  (0=Concurrent 1=PDLP 2=DualSimplex 3=Barrier)"
    echo "  presolve        : ${PRESOLVE}"
    echo "  visible device  : ${HIP_VISIBLE_DEVICES}"
    echo "  data dir        : ${DATA_DIR}"
    echo "  output dir      : ${OUTPUT_DIR}"
    echo "  solver binary   : ${SOLVE_LP}"
    echo "=========================================="
} | tee -a "${RUN_LOG}"

echo "instance,exit_code,wall_seconds,status,objective,iterations,solver_time_s,log_file" > "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Run loop
# ---------------------------------------------------------------------------

BENCH_START=$(date +%s)
HARD_STOP=$((BENCH_START + TIME_BUDGET * 115 / 100))   # 1.15x safety margin
COMPLETED=0
SKIPPED=0

# Parse the solver's summary line out of a per-instance log. The PDLP solver
# emits a line of the form (see cpp/src/linear_programming/solve.cu:557):
#   Status: <status>   Objective: <value>  Iterations: <int>  Time: <t>s, Total time <t>s
# Echoes "status,objective,iterations,solver_time" or "NA,NA,NA,NA" if not found.
parse_solver_summary() {
    local log="$1"
    if [[ ! -f "${log}" ]]; then
        echo "NA,NA,NA,NA"
        return
    fi
    # Take the *last* matching line; the solver may print several.
    local line
    line=$(grep -E 'Status:.*Objective:.*Iterations:.*Time:' "${log}" | tail -1)
    if [[ -z "${line}" ]]; then
        echo "NA,NA,NA,NA"
        return
    fi
    local status objective iterations solver_time
    status=$(echo "${line}"     | sed -nE 's/.*Status:[[:space:]]+([^[:space:]]+).*/\1/p')
    objective=$(echo "${line}"  | sed -nE 's/.*Objective:[[:space:]]+([-+0-9.eE]+).*/\1/p')
    iterations=$(echo "${line}" | sed -nE 's/.*Iterations:[[:space:]]+([0-9]+).*/\1/p')
    solver_time=$(echo "${line}" | sed -nE 's/.*[^l] Time:[[:space:]]+([0-9.]+)s.*/\1/p')
    echo "${status:-NA},${objective:-NA},${iterations:-NA},${solver_time:-NA}"
}

for instance in "${INSTANCES[@]}"; do
    mps_file="${DATA_DIR}/${instance}/${instance}.mps"
    log_file="${OUTPUT_DIR}/${instance}.log"
    elapsed=$(( $(date +%s) - BENCH_START ))
    remaining=$(( TIME_BUDGET - elapsed ))

    if (( $(date +%s) >= HARD_STOP )); then
        echo "[$(date +%H:%M:%S)] HARD STOP: elapsed=${elapsed}s exceeds 1.15x budget; aborting remaining instances" \
            | tee -a "${RUN_LOG}"
        echo "${instance},ABORTED,0,NA,NA,NA,NA,${log_file}" >> "${SUMMARY_CSV}"
        break
    fi

    if [[ ! -f "${mps_file}" ]]; then
        echo "[$(date +%H:%M:%S)] SKIP ${instance}: ${mps_file} not found" | tee -a "${RUN_LOG}"
        echo "${instance},MISSING,0,NA,NA,NA,NA,${log_file}" >> "${SUMMARY_CSV}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[$(date +%H:%M:%S)] (${COMPLETED}/${#INSTANCES[@]}) solving ${instance} (cap=${TIME_LIMIT}s, elapsed=${elapsed}s)" \
        | tee -a "${RUN_LOG}"

    start=$(date +%s)
    "${SOLVE_LP}" \
        --path "${mps_file}" \
        --method "${METHOD}" \
        --time-limit "${TIME_LIMIT}" \
        --presolve "${PRESOLVE}" \
        > "${log_file}" 2>&1
    exit_code=$?
    end=$(date +%s)
    wall=$((end - start))

    summary=$(parse_solver_summary "${log_file}")
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
