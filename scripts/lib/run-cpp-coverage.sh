#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Phase D: LLVM source-based C++ coverage for libcuopt (in-container).
#
# 1. Installs llvm-20 (llvm-cov-20 / llvm-profdata-20) if missing
# 2. Rebuilds libcuopt into cpp/build-coverage with -fprofile-instr-generate
# 3. Runs ctest (27 gtests) under LLVM_PROFILE_FILE
# 4. Merges .profraw and emits terminal + HTML reports under RESULTS_DIR
#
# Usage (inside rocopt-tester:local):
#   bash /rocopt-release/scripts/lib/run-cpp-coverage.sh [--skip-datasets] [--skip-rebuild]

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${_SCRIPT_DIR}/common.sh"

ROCOPT_DIR="${ROCOPT_DIR:-/rocopt-release}"
RESULTS_DIR="${RESULTS_DIR:-${ROCOPT_DIR}/test-results}"
COVERAGE_BUILD_DIR="${ROCOPT_DIR}/cpp/build-coverage"
PROFRAW_DIR="${RESULTS_DIR}/cpp-coverage-profraw"
PROFDATA="${RESULTS_DIR}/cpp-coverage.profdata"
REPORT_TXT="${RESULTS_DIR}/cpp-coverage-report.txt"
REPORT_HTML="${RESULTS_DIR}/cpp-coverage-html"
MARKER="${COVERAGE_BUILD_DIR}/.coverage_build_done"

SKIP_DATASETS=0
SKIP_REBUILD=0
for arg in "$@"; do
    case "${arg}" in
        --skip-datasets) SKIP_DATASETS=1 ;;
        --skip-rebuild) SKIP_REBUILD=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--skip-datasets] [--skip-rebuild]"
            exit 0
            ;;
        *)
            echo "unknown argument: ${arg}" >&2
            exit 3
            ;;
    esac
done

LLVM_COV="${LLVM_COV:-llvm-cov-20}"
LLVM_PROFDATA="${LLVM_PROFDATA:-llvm-profdata-20}"

ensure_build_deps() {
    require_cmd apt-get
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    local pkgs=()
    command -v "${LLVM_COV}" >/dev/null 2>&1 \
        && command -v "${LLVM_PROFDATA}" >/dev/null 2>&1 \
        || pkgs+=(llvm-20)
    [ -f /usr/include/bzlib.h ] || pkgs+=(libbz2-dev)
    [ -f /usr/include/zlib.h ] || pkgs+=(zlib1g-dev)
    if [ "${#pkgs[@]}" -eq 0 ]; then
        return 0
    fi
    log_step "Installing build deps: ${pkgs[*]}"
    apt-get install -y -qq "${pkgs[@]}"
    require_cmd "${LLVM_COV}" "${LLVM_PROFDATA}"
}

build_libcuopt_with_coverage() {
    if [ "${SKIP_REBUILD}" -eq 1 ] && [ -f "${MARKER}" ]; then
        log_info "Skipping rebuild (--skip-rebuild, marker present)"
        return 0
    fi

    log_step "Building libcuopt with LLVM coverage instrumentation"
    log_info "Build dir: ${COVERAGE_BUILD_DIR}"

    export LIBCUOPT_BUILD_DIR="${COVERAGE_BUILD_DIR}"
    # Respect entrypoint/bind-mount (e.g. /src/ROCmDS-cmake); fall back for dockerfile.rocm.local layout
    # only when that local checkout actually exists. Otherwise leave the variable unset so
    # CMake can use the normal FetchContent path.
    if [ -n "${ROCMDS_CMAKE_LOCAL_PATH:-}" ]; then
        export ROCMDS_CMAKE_LOCAL_PATH
    elif [ -d "${ROCOPT_DIR}/cmake/ROCmDS-cmake" ]; then
        export ROCMDS_CMAKE_LOCAL_PATH="${ROCOPT_DIR}/cmake/ROCmDS-cmake"
    else
        unset ROCMDS_CMAKE_LOCAL_PATH
    fi
    export CONDA_PREFIX="${CONDA_PREFIX:-/root/miniforge3/envs/cuopt_dev}"
    export PREFIX="${CONDA_PREFIX}"
    export PARALLEL_LEVEL="${PARALLEL_LEVEL:-$(nproc)}"

    # build.sh splits --cmake-args on whitespace; use a toolchain file so
    # multi-flag CMAKE_*_FLAGS values are not broken apart.
    local toolchain="/tmp/rocopt-coverage-toolchain.cmake"
    cat > "${toolchain}" <<'EOF'
# Release + debug symbols: avoid -g (Debug) which enables ASSERT_MODE and breaks
# several test TUs (cuopt_assert + string messages). Coverage mapping still works.
set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fprofile-instr-generate -fcoverage-mapping")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fprofile-instr-generate -fcoverage-mapping")
set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -fprofile-instr-generate -fcoverage-mapping")
EOF
    cd "${ROCOPT_DIR}"
    # build.sh requires --cmake-args="..." (quoted value) or it treats the flag as invalid.
    ./build.sh --use-rocm libcuopt \
        --cmake-args=\"-DCMAKE_TOOLCHAIN_FILE=${toolchain}\"

    touch "${MARKER}"
    log_info "Coverage build finished"
}

collect_profiles_and_report() {
    log_step "Merging LLVM profile data"
    mkdir -p "${RESULTS_DIR}"
    rm -f "${PROFDATA}"

    local had_profraw_nullglob=0
    shopt -q nullglob && had_profraw_nullglob=1
    shopt -s nullglob
    local profraws=( "${PROFRAW_DIR}"/*.profraw )
    if [ "${had_profraw_nullglob}" -eq 1 ]; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi

    if [ "${#profraws[@]}" -eq 0 ]; then
        die "no .profraw files found under ${PROFRAW_DIR}"
    fi

    log_info "Merging ${#profraws[@]} profraw file(s)"
    "${LLVM_PROFDATA}" merge -sparse "${profraws[@]}" -o "${PROFDATA}"

    local lib="${COVERAGE_BUILD_DIR}/libcuopt.so"
    [ -f "${lib}" ] || die "instrumented libcuopt.so not found: ${lib}"

    log_step "Generating C++ coverage report (terminal)"
    local had_globstar=0
    local had_nullglob=0
    shopt -q globstar && had_globstar=1
    shopt -q nullglob && had_nullglob=1
    shopt -s globstar nullglob
    {
        echo "rocopt C++ coverage (LLVM instr-profile)"
        echo "Profile: ${PROFDATA}"
        echo "Library: ${lib}"
        echo ""
        "${LLVM_COV}" report "${lib}" -instr-profile="${PROFDATA}" \
            -ignore-filename-regex='.*/tests/.*|.*/build-coverage/_deps/.*|.*/papilo_patched/.*'
        echo ""
        echo "Per-test binary summary:"
        for t in "${COVERAGE_BUILD_DIR}"/tests/**/*_TEST; do
            [ -x "${t}" ] || continue
            echo "--- $(basename "${t}") ---"
            "${LLVM_COV}" report "${t}" "${lib}" -instr-profile="${PROFDATA}" 2>/dev/null \
                | tail -1 || true
        done
    } | tee "${REPORT_TXT}"
    [ "${had_globstar}" -eq 1 ] || shopt -u globstar
    [ "${had_nullglob}" -eq 1 ] || shopt -u nullglob

    log_step "Generating HTML report"
    rm -rf "${REPORT_HTML}"
    mkdir -p "${REPORT_HTML}"
    "${LLVM_COV}" show "${lib}" -instr-profile="${PROFDATA}" \
        -format=html -output-dir="${REPORT_HTML}" \
        -ignore-filename-regex='.*/tests/.*|.*/build-coverage/_deps/.*|.*/papilo_patched/.*'

    log_info "Terminal report: ${REPORT_TXT}"
    log_info "HTML report:     ${REPORT_HTML}/index.html"

    local artifacts_folder="${ARTIFACTS_FOLDER:-/artifacts}"
    mkdir -p "${artifacts_folder}"
    local llvm_cov_json="${artifacts_folder}/llvm-cov_code_coverage.json"
    log_step "Exporting platform coverage JSON: ${llvm_cov_json}"
    # llvm-cov export: -format=text is JSON (LLVM naming); lcov is the other export format.
    # Matches other AISW code-coverage jobs (dgl, aisw-dummy-software) and manifest json_file_name.
    "${LLVM_COV}" export "${lib}" -instr-profile="${PROFDATA}" \
        -ignore-filename-regex='.*/tests/.*|.*/build-coverage/_deps/.*|.*/papilo_patched/.*' \
        -format=text > "${llvm_cov_json}"
    log_info "llvm-cov export: ${llvm_cov_json}"
}

main() {
    require_cmd cmake ninja ctest amdclang++

    ensure_build_deps
    build_libcuopt_with_coverage

    export ROCOPT_CPP_BUILD_DIR="${COVERAGE_BUILD_DIR}"

    # libcuopt coverage build uses cpp/CMakeLists.txt add_subdirectory(libmps_parser) ->
    # ${COVERAGE_BUILD_DIR}/libmps_parser, not cpp/libmps_parser/build (standalone target).
    local ld_paths=()
    if [ -d "${COVERAGE_BUILD_DIR}/libmps_parser" ]; then
        ld_paths+=("${COVERAGE_BUILD_DIR}/libmps_parser")
    elif [ -d "${ROCOPT_DIR}/cpp/libmps_parser/build" ]; then
        ld_paths+=("${ROCOPT_DIR}/cpp/libmps_parser/build")
    fi
    ld_paths+=("${COVERAGE_BUILD_DIR}")
    if [ -n "${CONDA_PREFIX:-}" ] && [ -d "${CONDA_PREFIX}/lib" ]; then
        ld_paths+=("${CONDA_PREFIX}/lib")
    fi
    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        ld_paths+=("${LD_LIBRARY_PATH}")
    fi
    export LD_LIBRARY_PATH="$(IFS=:; echo "${ld_paths[*]}")"

    # Test binaries are linked with DT_RPATH (legacy), whose first entry is
    # ${CONDA_PREFIX}/lib. DT_RPATH is consulted BEFORE LD_LIBRARY_PATH, so the
    # loader otherwise resolves libcuopt.so / libmps_parser.so to the
    # production wheel install rather than our instrumented build, producing
    # nearly-empty profraw files.
    #
    # LD_PRELOAD is processed before RPATH lookup, so force-mapping the
    # instrumented .so here ensures the NEEDED libcuopt.so / libmps_parser.so
    # entries resolve to the coverage build for every test binary launched
    # under ctest.
    local preload_libs=()
    [ -f "${COVERAGE_BUILD_DIR}/libcuopt.so" ] \
        && preload_libs+=("${COVERAGE_BUILD_DIR}/libcuopt.so")
    if [ -d "${COVERAGE_BUILD_DIR}/libmps_parser" ] \
       && [ -f "${COVERAGE_BUILD_DIR}/libmps_parser/libmps_parser.so" ]; then
        preload_libs+=("${COVERAGE_BUILD_DIR}/libmps_parser/libmps_parser.so")
    fi
    if [ "${#preload_libs[@]}" -gt 0 ]; then
        export LD_PRELOAD="$(IFS=:; echo "${preload_libs[*]}")${LD_PRELOAD:+:${LD_PRELOAD}}"
        log_info "LD_PRELOAD=${LD_PRELOAD}"
    fi

    mkdir -p "${PROFRAW_DIR}"
    rm -f "${PROFRAW_DIR}"/*.profraw
    export LLVM_PROFILE_FILE="${PROFRAW_DIR}/profile-%p-%m.profraw"

    local test_args=(--cpp)
    [ "${SKIP_DATASETS}" -eq 1 ] && test_args+=(--skip-datasets)

    log_step "Running C++ tests under LLVM_PROFILE_FILE"
    local test_ec=0
    bash "${_SCRIPT_DIR}/in-container-tests.sh" "${test_args[@]}" || test_ec=$?

    collect_profiles_and_report

    if [ "${test_ec}" -ne 0 ]; then
        log_error "C++ tests exited with ${test_ec}; coverage reports were still generated"
        exit 1
    fi

    log_step "Phase D C++ coverage complete"
}

main "$@"
