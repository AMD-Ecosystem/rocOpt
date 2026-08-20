#!/bin/bash

# SPDX-License-Identifier: Apache-2.0
#
# Multi-GPU throughput dispatcher for the short LP / MIP pre-flight benchmarks.
#
# *** NOT FOR PUBLISHED NUMBERS ***
# Uses the SAME curated subsets as benchmark_lp_mittelmann_short.sh and
# benchmark_mip_miplib_short.sh (it reuses their instance lists via LIST_ONLY),
# so its numbers carry the same "internal signal only" caveat.
#
# What it does
# ------------
# The sibling short scripts solve one instance at a time on a single GPU. This
# dispatcher fans the identical instance list across N GPUs, running one
# concurrent solve per GPU. That shortens the *total* suite wall time by up to
# ~N x, WITHOUT changing per-instance solve time (each solve still owns one
# whole GPU). So:
#   - per-instance numbers stay directly comparable to a single-GPU run
#   - "total wall time" is the only figure that should improve with more GPUs
#
# This is exactly the knob to compare a 1-GPU run against an 8-GPU run:
#   NGPUS=1 BENCH=lp  benchmark_multi_gpu.sh
#   NGPUS=8 BENCH=lp  benchmark_multi_gpu.sh
# Both append a row to <CUOPT_HOME>/benchmarks/multigpu_compare.csv with:
#   machine, benchmark, n_instances, per-instance time, total budget,
#   worst-case wall, total wall time
#
# Environment overrides
# ---------------------
#   BENCH         lp | mip                         (default: lp)
#   TIER          smoke | short | medium           (default: short)
#   NGPUS         number of GPUs to use            (default: all detected)
#   GPU_LIST      explicit comma list, e.g. 0,1,2,3 (overrides NGPUS)
#   TIME_LIMIT    per-instance seconds             (default: tier default)
#   METHOD        LP only: 0=Concurrent 1=PDLP 2=DualSimplex 3=Barrier (def 1)
#   PRESOLVE      LP only: 0|1                      (default: per method)
#   KILL_GRACE    MIP only: secs past cap -> SIGTERM (default: 60)
#   KILL_HARD     MIP only: secs past SIGTERM -> SIGKILL (default: 30)
#   DATA_DIR      MPS files location               (default: per benchmark)
#   OUTPUT_DIR    logs                             (default: ./<bench>_multigpu_<plat>_<ts>)
#   COMPARE_CSV   shared 1-vs-N comparison file     (default: <CUOPT_HOME>/benchmarks/multigpu_compare.csv)
#   SKIP_DOWNLOAD if set, do not download datasets
#
# Usage:
#   benchmarks/linear_programming/utils/benchmark_multi_gpu.sh
#   NGPUS=8 BENCH=mip TIER=short benchmarks/linear_programming/utils/benchmark_multi_gpu.sh

set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CUOPT_HOME="$( cd "$SCRIPT_DIR/../../../" && pwd )"

BENCH="${BENCH:-lp}"
TIER="${TIER:-short}"

case "${BENCH}" in
    lp)
        SIBLING="${SCRIPT_DIR}/benchmark_lp_mittelmann_short.sh"
        SOLVER="${CUOPT_HOME}/cpp/build/solve_LP"
        DEFAULT_DATA_DIR="${CUOPT_HOME}/benchmarks/linear_programming/datasets"
        BENCH_LABEL="mittelmann_lp"
        ;;
    mip)
        SIBLING="${SCRIPT_DIR}/benchmark_mip_miplib_short.sh"
        SOLVER="${CUOPT_HOME}/cpp/build/solve_MIP"
        DEFAULT_DATA_DIR="${CUOPT_HOME}/benchmarks/linear_programming/mip_datasets"
        BENCH_LABEL="miplib_mip"
        MIPLIB_BASE_URL="https://miplib.zib.de/WebData/instances"
        ;;
    *)
        echo "ERROR: unknown BENCH='${BENCH}' (expected: lp | mip)" >&2
        exit 2
        ;;
esac

DATA_DIR="${DATA_DIR:-${DEFAULT_DATA_DIR}}"

if [[ ! -f "${SIBLING}" ]]; then
    echo "ERROR: sibling script not found: ${SIBLING}" >&2
    exit 3
fi
if [[ ! -x "${SOLVER}" ]]; then
    echo "ERROR: solver binary not found or not executable: ${SOLVER}" >&2
    echo "Build it first (see the sibling short script's rebuild hint)." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Pull the resolved plan (tier defaults + curated instance list) straight from
# the sibling script so the two can never drift out of sync.
# ---------------------------------------------------------------------------
PLAN="$(LIST_ONLY=1 BENCH="" TIER="${TIER}" METHOD="${METHOD:-}" PRESOLVE="${PRESOLVE:-}" \
        KILL_GRACE="${KILL_GRACE:-}" KILL_HARD="${KILL_HARD:-}" \
        bash "${SIBLING}")" || {
    echo "ERROR: failed to enumerate instances from ${SIBLING}" >&2
    exit 3
}

INSTANCES=()
PLAN_TIME_LIMIT=""
PLAN_METHOD=""
PLAN_PRESOLVE=""
PLAN_KILL_GRACE=""
PLAN_KILL_HARD=""
while IFS= read -r line; do
    case "${line}" in
        TIME_LIMIT=*)  PLAN_TIME_LIMIT="${line#TIME_LIMIT=}" ;;
        METHOD=*)      PLAN_METHOD="${line#METHOD=}" ;;
        PRESOLVE=*)    PLAN_PRESOLVE="${line#PRESOLVE=}" ;;
        KILL_GRACE=*)  PLAN_KILL_GRACE="${line#KILL_GRACE=}" ;;
        KILL_HARD=*)   PLAN_KILL_HARD="${line#KILL_HARD=}" ;;
        INSTANCE=*)    INSTANCES+=("${line#INSTANCE=}") ;;
    esac
done <<< "${PLAN}"

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
    echo "ERROR: no instances resolved from ${SIBLING} (TIER=${TIER})" >&2
    exit 3
fi

TIME_LIMIT="${TIME_LIMIT:-${PLAN_TIME_LIMIT}}"
METHOD="${METHOD:-${PLAN_METHOD:-1}}"
PRESOLVE="${PRESOLVE:-${PLAN_PRESOLVE:-0}}"
KILL_GRACE="${KILL_GRACE:-${PLAN_KILL_GRACE:-60}}"
KILL_HARD="${KILL_HARD:-${PLAN_KILL_HARD:-30}}"
SOLVE_DEADLINE=$((TIME_LIMIT + KILL_GRACE))

# ---------------------------------------------------------------------------
# GPU selection.
# ---------------------------------------------------------------------------
detect_gpu_count() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -L 2>/dev/null | grep -c '^GPU '
    elif command -v rocminfo &>/dev/null; then
        # Count GPU agents (Device Type: GPU), not CPU agents.
        rocminfo 2>/dev/null | awk '/Device Type:/ {print $NF}' | grep -c 'GPU'
    else
        echo 1
    fi
}

if [[ -n "${GPU_LIST:-}" ]]; then
    IFS=',' read -r -a GPU_IDS <<< "${GPU_LIST}"
else
    DETECTED="$(detect_gpu_count)"
    [[ "${DETECTED}" =~ ^[0-9]+$ && "${DETECTED}" -ge 1 ]] || DETECTED=1
    NGPUS="${NGPUS:-${DETECTED}}"
    if (( NGPUS > DETECTED )); then
        echo "WARN: requested NGPUS=${NGPUS} but only ${DETECTED} GPU(s) detected; capping to ${DETECTED}" >&2
        NGPUS="${DETECTED}"
    fi
    GPU_IDS=()
    for (( g=0; g<NGPUS; g++ )); do GPU_IDS+=("${g}"); done
fi
NGPUS="${#GPU_IDS[@]}"

# ---------------------------------------------------------------------------
# Platform / output setup.
# ---------------------------------------------------------------------------
export CUDA_MODULE_LOADING=EAGER

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
[[ -z "${GPU_NAME}" ]] && GPU_NAME="unknown"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-${CUOPT_HOME}/benchmarks/${BENCH}_multigpu_${PLATFORM}_${TIMESTAMP}}"
PARTS_DIR="${OUTPUT_DIR}/parts"
mkdir -p "${PARTS_DIR}"
mkdir -p "${DATA_DIR}"

SUMMARY_CSV="${OUTPUT_DIR}/summary.csv"
RUN_LOG="${OUTPUT_DIR}/run.log"
COMPARE_CSV="${COMPARE_CSV:-${CUOPT_HOME}/benchmarks/multigpu_compare.csv}"

HOSTNAME_STR="$(hostname)"
MACHINE="${GPU_NAME} @ ${HOSTNAME_STR}"

# ceil(n / ngpus) waves, each wave bounded by the per-instance cap. For MIP the
# hard cap is cap + grace + kill; for LP it is just the cap.
per_instance_ceiling=$TIME_LIMIT
if [[ "${BENCH}" == "mip" ]]; then
    per_instance_ceiling=$((TIME_LIMIT + KILL_GRACE + KILL_HARD))
fi
WAVES=$(( (${#INSTANCES[@]} + NGPUS - 1) / NGPUS ))
WORSTCASE_WALL=$(( WAVES * per_instance_ceiling ))
TOTAL_BUDGET=$(( ${#INSTANCES[@]} * TIME_LIMIT ))

# ---------------------------------------------------------------------------
# Dataset download (delegated to the same mechanisms the siblings use).
# ---------------------------------------------------------------------------
find_mps_file() {
    local inst="$1" cand
    for cand in \
        "${DATA_DIR}/${inst}.mps" \
        "${DATA_DIR}/${inst}/${inst}.mps" \
        "${DATA_DIR}/${inst}/${inst}" \
        "${DATA_DIR}/${inst}"; do
        [[ -f "${cand}" ]] && { echo "${cand}"; return 0; }
    done
    return 1
}

download_datasets() {
    [[ -n "${SKIP_DOWNLOAD:-}" ]] && return 0
    if [[ "${BENCH}" == "lp" ]]; then
        local get_datasets="${SCRIPT_DIR}/get_datasets.py"
        echo "Downloading any missing Mittelmann LP instances into ${DATA_DIR}..." | tee -a "${RUN_LOG}"
        python3 "${get_datasets}" -LPfeasible \
            -instance-download-path "${DATA_DIR}" 2>&1 | tee -a "${RUN_LOG}"
    else
        echo "Downloading any missing MIPLIB instances into ${DATA_DIR}..." | tee -a "${RUN_LOG}"
        local inst url gz
        for inst in "${INSTANCES[@]}"; do
            find_mps_file "${inst}" >/dev/null && continue
            url="${MIPLIB_BASE_URL}/${inst}.mps.gz"
            gz="${DATA_DIR}/${inst}.mps.gz"
            echo "  fetching ${url}" | tee -a "${RUN_LOG}"
            if wget -4 --tries=3 --continue --progress=dot:mega --retry-connrefused \
                    "${url}" -O "${gz}" 2>&1 | tee -a "${RUN_LOG}"; then
                gunzip -f "${gz}" || echo "  WARN: gunzip failed for ${gz}" | tee -a "${RUN_LOG}"
            else
                echo "  WARN: download failed for ${url}" | tee -a "${RUN_LOG}"
                rm -f "${gz}"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Per-instance summary parsers (kept in sync with the sibling scripts).
# ---------------------------------------------------------------------------
parse_lp_summary() {
    local log="$1"
    [[ -f "${log}" ]] || { echo "NA,NA,NA,NA"; return; }
    local line
    line=$(grep -E 'Status:.*Objective:.*Iterations:.*Time:' "${log}" | tail -1)
    [[ -z "${line}" ]] && { echo "NA,NA,NA,NA"; return; }
    local status objective iterations solver_time
    status=$(echo "${line}"      | sed -nE 's/.*Status:[[:space:]]+([^[:space:]]+).*/\1/p')
    objective=$(echo "${line}"   | sed -nE 's/.*Objective:[[:space:]]+([-+0-9.eE]+).*/\1/p')
    iterations=$(echo "${line}"  | sed -nE 's/.*Iterations:[[:space:]]+([0-9]+).*/\1/p')
    solver_time=$(echo "${line}" | sed -nE 's/.*[^l] Time:[[:space:]]+([0-9.]+)s.*/\1/p')
    echo "${status:-NA},${objective:-NA},${iterations:-NA},${solver_time:-NA}"
}

parse_mip_summary() {
    local log="$1"
    [[ -f "${log}" ]] || { echo "NA,NA,NA"; return; }
    local status objective solver_time sol_line
    sol_line=$(grep -E ': (solution found|no solution found)' "${log}" | tail -1)
    if [[ -z "${sol_line}" ]]; then
        status="NA"; objective="NA"
    elif echo "${sol_line}" | grep -q 'no solution found'; then
        status="NoSolution"; objective="NA"
    else
        status="FeasibleOrOptimal"
        objective=$(echo "${sol_line}" | sed -nE 's/.*solution found,[[:space:]]+obj:[[:space:]]+([-+0-9.eE]+).*/\1/p')
        [[ -z "${objective}" ]] && objective="NA"
    fi
    local solver_ms
    solver_ms=$(grep -E 'run_solver[[:space:]]+[0-9]+' "${log}" | tail -1 | sed -nE 's/.*run_solver[[:space:]]+([0-9]+).*/\1/p')
    if [[ -n "${solver_ms}" ]]; then
        solver_time=$(awk "BEGIN{printf \"%.3f\", ${solver_ms}/1000.0}")
    else
        solver_time="NA"
    fi
    echo "${status:-NA},${objective:-NA},${solver_time:-NA}"
}

# ---------------------------------------------------------------------------
# Worker: solves one instance on one GPU and writes a self-contained CSV part.
# Timing is done inside the worker so scheduler poll lag never inflates walls.
# ---------------------------------------------------------------------------
run_one() {
    local gpu="$1" instance="$2"
    local log_file="${OUTPUT_DIR}/${instance}.log"
    local part="${PARTS_DIR}/${instance}.csv"
    export HIP_VISIBLE_DEVICES="${gpu}"
    export CUDA_VISIBLE_DEVICES="${gpu}"

    local mps_file start end wall exit_code summary
    if [[ "${BENCH}" == "lp" ]]; then
        mps_file="${DATA_DIR}/${instance}/${instance}.mps"
        if [[ ! -f "${mps_file}" ]]; then
            echo "${instance},${gpu},MISSING,0,NA,NA,NA,NA,${log_file}" > "${part}"
            return
        fi
        start=$(date +%s)
        "${SOLVER}" --path "${mps_file}" --method "${METHOD}" \
            --time-limit "${TIME_LIMIT}" --presolve "${PRESOLVE}" > "${log_file}" 2>&1
        exit_code=$?
        end=$(date +%s); wall=$((end - start))
        summary=$(parse_lp_summary "${log_file}")
        echo "${instance},${gpu},${exit_code},${wall},${summary},${log_file}" > "${part}"
    else
        mps_file="$(find_mps_file "${instance}" || true)"
        if [[ -z "${mps_file}" ]]; then
            echo "${instance},${gpu},MISSING,0,NA,NA,NA,${log_file}" > "${part}"
            return
        fi
        start=$(date +%s)
        timeout --kill-after="${KILL_HARD}s" "${SOLVE_DEADLINE}s" \
            "${SOLVER}" --path "${mps_file}" --time-limit "${TIME_LIMIT}" > "${log_file}" 2>&1
        exit_code=$?
        end=$(date +%s); wall=$((end - start))
        summary=$(parse_mip_summary "${log_file}")
        echo "${instance},${gpu},${exit_code},${wall},${summary},${log_file}" > "${part}"
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
{
    echo "=========================================="
    echo "Multi-GPU throughput dispatcher (${BENCH_LABEL})"
    echo "=========================================="
    echo "  platform        : ${PLATFORM}"
    echo "  machine         : ${MACHINE}"
    echo "  gpu             : ${GPU_NAME}"
    echo "  driver          : ${GPU_DRIVER}"
    echo "  benchmark       : ${BENCH_LABEL}"
    echo "  tier            : ${TIER}"
    echo "  gpus in use     : ${NGPUS}  (ids: ${GPU_IDS[*]})"
    echo "  instances       : ${#INSTANCES[@]}"
    echo "  per-instance    : ${TIME_LIMIT}s"
    if [[ "${BENCH}" == "lp" ]]; then
        echo "  method          : ${METHOD}  (0=Concurrent 1=PDLP 2=DualSimplex 3=Barrier)"
        echo "  presolve        : ${PRESOLVE}"
    else
        echo "  kill grace      : SIGTERM at ${SOLVE_DEADLINE}s, SIGKILL ${KILL_HARD}s later"
    fi
    echo "  total budget    : ${TOTAL_BUDGET}s  ($(awk "BEGIN{printf \"%.2f\", ${TOTAL_BUDGET}/3600}")h)  [sum of per-instance caps]"
    echo "  worst-case wall : ${WORSTCASE_WALL}s  (${WAVES} waves x ${per_instance_ceiling}s across ${NGPUS} gpu(s))"
    echo "  data dir        : ${DATA_DIR}"
    echo "  output dir      : ${OUTPUT_DIR}"
    echo "  solver binary   : ${SOLVER}"
    echo "=========================================="
} | tee -a "${RUN_LOG}"

download_datasets

# ---------------------------------------------------------------------------
# Scheduler: keep one live solve per GPU; assign next instance to any free GPU.
# ---------------------------------------------------------------------------
declare -A SLOT_PID
declare -A SLOT_INST

free_gpu() {
    local g pid
    for g in "${GPU_IDS[@]}"; do
        pid="${SLOT_PID[$g]:-}"
        if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
            echo "${g}"
            return 0
        fi
    done
    return 1
}

BENCH_START=$(date +%s)

for instance in "${INSTANCES[@]}"; do
    g=""
    while true; do
        if g="$(free_gpu)"; then break; fi
        sleep 1
    done
    echo "[$(date +%H:%M:%S)] dispatch ${instance} -> gpu ${g}" | tee -a "${RUN_LOG}"
    run_one "${g}" "${instance}" &
    SLOT_PID[$g]=$!
    SLOT_INST[$g]="${instance}"
done

wait
TOTAL=$(( $(date +%s) - BENCH_START ))

# ---------------------------------------------------------------------------
# Aggregate parts into a stable, instance-ordered summary.
# ---------------------------------------------------------------------------
if [[ "${BENCH}" == "lp" ]]; then
    echo "instance,gpu,exit_code,wall_seconds,status,objective,iterations,solver_time_s,log_file" > "${SUMMARY_CSV}"
else
    echo "instance,gpu,exit_code,wall_seconds,status,objective,solver_time_s,log_file" > "${SUMMARY_CSV}"
fi
COMPLETED=0
SKIPPED=0
for instance in "${INSTANCES[@]}"; do
    part="${PARTS_DIR}/${instance}.csv"
    if [[ -f "${part}" ]]; then
        cat "${part}" >> "${SUMMARY_CSV}"
        if grep -q ',MISSING,' "${part}"; then
            SKIPPED=$((SKIPPED + 1))
        else
            COMPLETED=$((COMPLETED + 1))
        fi
    fi
done

# ---------------------------------------------------------------------------
# Comparison row (this is the 1-GPU vs 8-GPU table the run is meant to feed).
# ---------------------------------------------------------------------------
if [[ ! -f "${COMPARE_CSV}" ]]; then
    echo "timestamp,machine,benchmark,tier,ngpus,n_instances,per_instance_s,total_budget_s,worstcase_wall_s,total_wall_s" > "${COMPARE_CSV}"
fi
echo "${TIMESTAMP},${MACHINE},${BENCH_LABEL},${TIER},${NGPUS},${#INSTANCES[@]},${TIME_LIMIT},${TOTAL_BUDGET},${WORSTCASE_WALL},${TOTAL}" >> "${COMPARE_CSV}"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
{
    echo "=========================================="
    echo "Multi-GPU benchmark complete"
    echo "=========================================="
    echo "  machine         : ${MACHINE}"
    echo "  benchmark       : ${BENCH_LABEL} (${TIER})"
    echo "  gpus in use     : ${NGPUS}"
    echo "  instances       : ${#INSTANCES[@]}"
    echo "  per-instance    : ${TIME_LIMIT}s"
    echo "  total budget    : ${TOTAL_BUDGET}s"
    echo "  worst-case wall : ${WORSTCASE_WALL}s"
    echo "  total wall time : ${TOTAL}s  ($(awk "BEGIN{printf \"%.2f\", ${TOTAL}/3600}")h)"
    echo "  completed       : ${COMPLETED}"
    echo "  skipped/missing : ${SKIPPED}"
    echo "  summary         : ${SUMMARY_CSV}"
    echo "  comparison row  : ${COMPARE_CSV}"
    echo "=========================================="
} | tee -a "${RUN_LOG}"
