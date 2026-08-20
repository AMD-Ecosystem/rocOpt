#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2021-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: ROCm port modifications (c) 2026
# SPDX-License-Identifier: Apache-2.0

set -e

NUMARGS=$#
ARGS=$*

# NOTE: ensure all dir changes are relative to the location of this
# script, and that this script resides in the repo dir!
REPODIR=$(cd "$(dirname "$0")"; pwd)
LIBCUOPT_BUILD_DIR=${LIBCUOPT_BUILD_DIR:=${REPODIR}/cpp/build}
LIBMPS_PARSER_BUILD_DIR=${LIBMPS_PARSER_BUILD_DIR:=${REPODIR}/cpp/libmps_parser/build}

# Detect platform: CUDA or ROCm
USE_ROCM=1
if command -v nvcc &> /dev/null; then
    USE_ROCM=0
    echo "Detected NVIDIA CUDA platform"
elif command -v hipcc &> /dev/null; then
    USE_ROCM=1
    echo "Detected AMD ROCm platform"
else
    echo "Warning: Neither CUDA nor ROCm detected. Defaulting to ROCm."
    USE_ROCM=1
fi

VALIDARGS="clean libcuopt libmps_parser cuopt_mps_parser cuopt cuopt_server cuopt_sh_client docs deb -a -b -g -fsanitize -tsan -msan -v -l= --verbose-pdlp --build-lp-only  --no-fetch-rapids --skip-c-python-adapters --skip-tests-build --skip-routing-build --skip-fatbin-write --host-lineinfo --use-cuda --use-rocm [--cmake-args=\\\"<args>\\\"] [--cache-tool=<tool>] -n --allgpuarch --ci-only-arch --show_depr_warn -h --help"
HELP="$0 [<target> ...] [<flag> ...]
 where <target> is:
   clean            - remove all existing build artifacts and configuration (start over)
   libcuopt         - build the cuopt C++ code
   libmps_parser    - build the libmps_parser C++ code
   cuopt_mps_parser - build the cuopt_mps_parser python package
   cuopt            - build the cuopt Python package
   cuopt_server     - build the cuopt_server Python package
   cuopt_sh_client  - build cuopt self host client
   docs             - build the docs
   deb              - build deb package (requires libcuopt to be built first)
 and <flag> is:
   -v               - verbose build mode
   -g               - build for debug
   -a               - Enable assertion (by default in debug mode)
   -b               - Build with benchmark settings
   -fsanitize       - Build with AddressSanitizer and UndefinedBehaviorSanitizer
   -tsan            - Build with ThreadSanitizer (cannot be used with -fsanitize or -msan)
   -msan            - Build with MemorySanitizer (cannot be used with -fsanitize or -tsan)
   -n               - no install step
   --use-cuda       - Force CUDA build (even if ROCm is detected)
   --use-rocm       - Force ROCm build (even if CUDA is detected)
   --no-fetch-rapids  - don't fetch rapids dependencies (CUDA only)
   -l=              - log level. Options are: TRACE | DEBUG | INFO | WARN | ERROR | CRITICAL | OFF. Default=INFO
   --verbose-pdlp   - verbose mode for pdlp solver
   --build-lp-only  - build only linear programming components, excluding routing package and MIP-specific files
   --skip-c-python-adapters - skip building C and Python adapter files (cython_solve.cu and cuopt_c.cpp)
   --skip-tests-build  - disable building of all tests
   --skip-routing-build - skip building routing components
   --skip-fatbin-write      - skip the fatbin write (CUDA only)
   --host-lineinfo           - build with debug line information for host code
   --cache-tool=<tool> - pass the build cache tool (eg: ccache, sccache, distcc) that will be used
                      to speedup the build process.
   --cmake-args=\\\"<args>\\\"   - pass arbitrary list of CMake configuration options (escape all quotes in argument)
   --allgpuarch     - build for all supported GPU architectures
   --ci-only-arch   - build for volta and ampere only (CUDA) or gfx90a/gfx908 (ROCm)
   --show_depr_warn - show cmake deprecation warnings
   -h               - print this text

 default action (no args) is to build and install 'libcuopt' then 'cuopt' then 'docs' targets

 libcuopt build dir is: ${LIBCUOPT_BUILD_DIR}

 Set env var LIBCUOPT_BUILD_DIR to override libcuopt build dir.
"
CUOPT_MPS_PARSER_BUILD_DIR=${REPODIR}/python/cuopt/cuopt/linear_programming/build
PY_LIBCUOPT_BUILD_DIR=${REPODIR}/python/libcuopt/build
CUOPT_BUILD_DIR=${REPODIR}/python/cuopt/build
CUOPT_SERVER_BUILD_DIR=${REPODIR}/python/cuopt_server/build
CUOPT_SH_CLIENT_BUILD_DIR=${REPODIR}/python/cuopt_self_hosted/build
DOCS_BUILD_DIR=${REPODIR}/docs/cuopt/build
BUILD_DIRS="${LIBCUOPT_BUILD_DIR} ${LIBMPS_PARSER_BUILD_DIR} ${CUOPT_BUILD_DIR} ${CUOPT_SERVER_BUILD_DIR} ${CUOPT_SERVICE_CLIENT_BUILD_DIR} ${CUOPT_SH_CLIENT_BUILD_DIR} ${CUOPT_MPS_PARSER_BUILD_DIR} ${PY_LIBCUOPT_BUILD_DIR} ${DOCS_BUILD_DIR}"

# Set defaults for vars modified by flags to this script
VERBOSE_FLAG=""
BUILD_TYPE=Release
DEFINE_ASSERT=False
DEFINE_PDLP_VERBOSE_MODE=False
INSTALL_TARGET=install
BUILD_DISABLE_DEPRECATION_WARNING=ON
BUILD_ALL_GPU_ARCH=0
BUILD_CI_ONLY=0
BUILD_LP_ONLY=0
BUILD_SANITIZER=0
BUILD_TSAN=0
BUILD_MSAN=0
SKIP_C_PYTHON_ADAPTERS=0
SKIP_TESTS_BUILD=0
SKIP_ROUTING_BUILD=0
WRITE_FATBIN=1
HOST_LINEINFO=0
CACHE_ARGS=()
PYTHON_ARGS_FOR_INSTALL=("-m" "pip" "install" "--no-build-isolation" "--no-deps")
LOGGING_ACTIVE_LEVEL="INFO"
FETCH_RAPIDS=ON

# Set defaults for vars that may not have been defined externally
INSTALL_PREFIX=${PREFIX:=${CONDA_PREFIX}}
BUILD_ABI=${BUILD_ABI:=ON}

export CMAKE_GENERATOR=Ninja

# ROCm-specific pip configuration: use AMD PyPI index and constraints file
# to prevent NVIDIA stub packages (e.g. amd-cupy==0.0.2) from being installed.
ROCM_PIP_CONSTRAINTS="${REPODIR}/rocm_pip_constraints.txt"

# AMD PyPI versioned index — packages like amd-pylibraft, amd-hipdf, etc.
# are published under version-specific indexes (e.g. rocm-7.2.3/simple).
# The open rocm-7.2.3 index hosts the ROCm-DS 26.03 packages used here.
#
# Overridable so a caller that already knows which ROCm version it is targeting
# can keep this in step with it. docker/Dockerfile.rocm_ci exports
# AMD_PYPI_ROCM_VERSION for exactly this reason: it builds on ROCm 7.1.1 but
# installs wheels that must run on the 7.2.3 release image, so the two places
# that name an index version must not drift apart.
AMD_PYPI_ROCM_VERSION="${AMD_PYPI_ROCM_VERSION:-7.2.3}"
AMD_PYPI_INDEX="${AMD_PYPI_INDEX:-https://pypi.amd.com/rocm-${AMD_PYPI_ROCM_VERSION}/simple}"

function hasArg {
    (( NUMARGS != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

function buildAll {
    (( NUMARGS == 0 )) || ! (echo " ${ARGS} " | grep -q " [^-]\+ ")
}

function cacheTool {
    if [[ $(echo "$ARGS" | { grep -Eo "\-\-cache\-tool" || true; } | wc -l ) -gt 1 ]]; then
        echo "Multiple --cache-tool options were provided, please provide only one: ${ARGS}"
        exit 1
    fi
    if [[ -n $(echo "$ARGS" | { grep -E "\-\-cache\-tool" || true; } ) ]]; then
        CACHE_TOOL=$(echo "$ARGS" | sed -e 's/.*--cache-tool=//' -e 's/ .*//')
        if [[ -n ${CACHE_TOOL} ]]; then
            ARGS=${ARGS//--cache-tool=$CACHE_TOOL/}
            if [ ${USE_ROCM} -eq 1 ]; then
                CACHE_ARGS=("-DCMAKE_HIP_COMPILER_LAUNCHER=${CACHE_TOOL}" "-DCMAKE_C_COMPILER_LAUNCHER=${CACHE_TOOL}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${CACHE_TOOL}")
            else
                CACHE_ARGS=("-DCMAKE_CUDA_COMPILER_LAUNCHER=${CACHE_TOOL}" "-DCMAKE_C_COMPILER_LAUNCHER=${CACHE_TOOL}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${CACHE_TOOL}")
            fi
        fi
    fi
}

function loggingArgs {
    if [[ $(echo "$ARGS" | { grep -Eo "\-l=" || true; } | wc -l ) -gt 1 ]]; then
        echo "Multiple -l logging options were provided, please provide only one: ${ARGS}"
        exit 1
    fi

    LOG_LEVEL_LIST=("TRACE" "DEBUG" "INFO" "WARN" "ERROR" "CRITICAL" "OFF")

    if [[ -n $(echo "$ARGS" | { grep -E "\-l=" || true; } ) ]]; then
        LOGGING_ARGS=$(echo "$ARGS" | { grep -Eo "\-l=\S+" || true; })
        if [[ -n ${LOGGING_ARGS} ]]; then
            ARGS=${ARGS//$LOGGING_ARGS/}
            LOGGING_ARGS=$(echo "$LOGGING_ARGS" | sed -e 's/^"//' -e 's/"$//' | cut -c4- | grep -Eo "\S+" | tr '[:lower:]' '[:upper:]')
            if [[ "${LOG_LEVEL_LIST[*]}" =~ $LOGGING_ARGS ]]; then
                LOGGING_ACTIVE_LEVEL=$LOGGING_ARGS
            else
                echo "Invalid logging arg $LOGGING_ARGS, expected any of ${LOG_LEVEL_LIST[*]}"
                exit 1
            fi
        fi
    fi
}

function cmakeArgs {
    if [[ $(echo "$ARGS" | { grep -Eo "\-\-cmake\-args" || true; } | wc -l ) -gt 1 ]]; then
        echo "Multiple --cmake-args options were provided, please provide only one: ${ARGS}"
        exit 1
    fi

    if [[ -n $(echo "$ARGS" | { grep -E "\-\-cmake\-args" || true; } ) ]]; then
        EXTRA_CMAKE_ARGS=$(echo "$ARGS" | { grep -Eo "\-\-cmake\-args=\".+\"" || true; })
        if [[ -n ${EXTRA_CMAKE_ARGS} ]]; then
            ARGS=${ARGS//$EXTRA_CMAKE_ARGS/}
            EXTRA_CMAKE_ARGS=$(echo "$EXTRA_CMAKE_ARGS" | grep -Eo "\".+\"" | sed -e 's/^"//' -e 's/"$//')
        fi
    fi

    read -ra EXTRA_CMAKE_ARGS <<< "$EXTRA_CMAKE_ARGS"
}

if hasArg -h || hasArg --help; then
    echo "${HELP}"
    exit 0
fi

# Check for platform override flags
if hasArg --use-cuda; then
    USE_ROCM=0
    echo "Forcing CUDA build"
fi

if hasArg --use-rocm; then
    USE_ROCM=1
    echo "Forcing ROCm build"
fi

# Check for valid usage
if (( NUMARGS != 0 )); then
    cacheTool
    cmakeArgs
    loggingArgs
    for a in ${ARGS}; do
        if ! (echo " ${VALIDARGS} " | grep -q " ${a} "); then
            echo "Invalid option: ${a}"
            exit 1
        fi
    done
fi

# Process flags
if hasArg -v; then
    VERBOSE_FLAG="-v"
fi
if hasArg -g; then
    BUILD_TYPE=Debug
    DEFINE_ASSERT=true
fi
if hasArg -a; then
    DEFINE_ASSERT=true
fi
if hasArg -b; then
    DEFINE_BENCHMARK=true
fi
if hasArg --verbose-pdlp; then
    DEFINE_PDLP_VERBOSE_MODE=true
fi
if hasArg -n; then
    INSTALL_TARGET=""
fi
if hasArg --no-fetch-rapids; then
    FETCH_RAPIDS=OFF
fi
if hasArg --allgpuarch; then
    BUILD_ALL_GPU_ARCH=1
fi
if hasArg --ci-only-arch; then
    BUILD_CI_ONLY=1
fi
if hasArg --show_depr_warn; then
    BUILD_DISABLE_DEPRECATION_WARNING=OFF
fi
if hasArg --build-lp-only; then
    BUILD_LP_ONLY=1
    SKIP_ROUTING_BUILD=1
fi
if hasArg -fsanitize; then
    BUILD_SANITIZER=1
fi
if hasArg -tsan; then
    BUILD_TSAN=1
fi
if hasArg -msan; then
    BUILD_MSAN=1
fi
if hasArg --skip-c-python-adapters; then
    SKIP_C_PYTHON_ADAPTERS=1
fi
if hasArg --skip-tests-build; then
    SKIP_TESTS_BUILD=1
fi
if hasArg --skip-routing-build; then
    SKIP_ROUTING_BUILD=1
fi
if hasArg --skip-fatbin-write; then
    WRITE_FATBIN=0
fi
if hasArg --host-lineinfo; then
    HOST_LINEINFO=1
fi

function contains_string {
    local search_string="$1"
    shift
    local array=("$@")

    for element in "${array[@]}"; do
        if [[ "$element" == *"$search_string"* ]]; then
            return 0
        fi
    done

    return 1
}

# Append `-DFIND_CUOPT_CPP=ON` to CMAKE_ARGS unless a user specified the option.
if ! contains_string "DFIND_CUOPT_CPP" "${EXTRA_CMAKE_ARGS[@]}"; then
    EXTRA_CMAKE_ARGS+=("-DFIND_CUOPT_CPP=ON")
fi

if ! contains_string "DFIND_MPS_PARSER_CPP" "${EXTRA_CMAKE_ARGS[@]}"; then
    EXTRA_CMAKE_ARGS+=("-DFIND_MPS_PARSER_CPP=ON")
fi

# If clean given, run it prior to any other steps
if hasArg clean; then
    for bd in ${BUILD_DIRS}; do
        if [ -d "${bd}" ]; then
            find "${bd}" -mindepth 1 -delete
            rmdir "${bd}" || true
        fi
    done

    # Cleaning up python artifacts
    find "${REPODIR}"/python/ | grep -E "(__pycache__|\.pyc|\.pyo|\.so|\_skbuild$)"  | xargs rm -rf
fi

if [ ${BUILD_CI_ONLY} -eq 1 ] && [ ${BUILD_ALL_GPU_ARCH} -eq 1 ]; then
    echo "Options --ci-only-arch and --allgpuarch can not be used simultaneously"
    exit 1
fi

if [ ${BUILD_LP_ONLY} -eq 1 ] && [ ${SKIP_C_PYTHON_ADAPTERS} -eq 0 ]; then
    echo "ERROR: When using --build-lp-only, you must also specify --skip-c-python-adapters"
    echo "The C and Python adapter files (cython_solve.cu and cuopt_c.cpp) are not compatible with LP-only builds"
    exit 1
fi

if [ ${BUILD_SANITIZER} -eq 1 ] && [ ${BUILD_TSAN} -eq 1 ]; then
    echo "ERROR: -fsanitize and -tsan cannot be used together"
    exit 1
fi

if [ ${BUILD_SANITIZER} -eq 1 ] && [ ${BUILD_MSAN} -eq 1 ]; then
    echo "ERROR: -fsanitize and -msan cannot be used together"
    exit 1
fi

if [ ${BUILD_TSAN} -eq 1 ] && [ ${BUILD_MSAN} -eq 1 ]; then
    echo "ERROR: -tsan and -msan cannot be used together"
    exit 1
fi

# For ROCm builds, set pip environment so all pip invocations use AMD's
# package index and the constraints file that prevents stub downgrades.
if [ ${USE_ROCM} -eq 1 ]; then
    export PIP_EXTRA_INDEX_URL="${AMD_PYPI_INDEX}"
    if [ -f "${ROCM_PIP_CONSTRAINTS}" ]; then
        export PIP_CONSTRAINT="${ROCM_PIP_CONSTRAINTS}"
        echo "ROCm pip constraints: ${ROCM_PIP_CONSTRAINTS}"
    fi
    echo "ROCm AMD PyPI index: ${AMD_PYPI_INDEX}"

    # Ensure libcuopt.so and libmps_parser.so are findable at runtime.
    # After 'cmake --install', these libraries land in ${INSTALL_PREFIX}/lib.
    # The build directories are also included so that tests work even before
    # a full install (e.g. during incremental development).
    export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${LIBCUOPT_BUILD_DIR}:${LIBMPS_PARSER_BUILD_DIR}:${LD_LIBRARY_PATH}"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
fi

# Configure GPU architectures
if [ ${USE_ROCM} -eq 1 ]; then
    # ROCm GPU architectures
    if [ ${BUILD_ALL_GPU_ARCH} -eq 1 ]; then
        CUOPT_CMAKE_GPU_ARCHITECTURES="gfx900;gfx906;gfx908;gfx90a;gfx940;gfx941;gfx942;gfx950"
        echo "Building for *ALL* supported AMD GPU architectures..."
    elif [ ${BUILD_CI_ONLY} -eq 1 ]; then
        CUOPT_CMAKE_GPU_ARCHITECTURES="gfx90a;gfx908"
        echo "Building for CI AMD GPU architectures (gfx90a, gfx908)..."
    else
        # Honor explicit arch override; CI CPU builders pass ROCOPT_GPU_ARCH as a
        # multi-arch fat binary (gfx942;gfx950).  When unset, use the same default.
        if [ -n "${ROCOPT_GPU_ARCH:-}" ]; then
            CUOPT_CMAKE_GPU_ARCHITECTURES="${ROCOPT_GPU_ARCH}"
            echo "Building for ROCOPT_GPU_ARCH from environment: ${CUOPT_CMAKE_GPU_ARCHITECTURES}"
        else
            CUOPT_CMAKE_GPU_ARCHITECTURES="${ROCOPT_GPU_ARCH_FALLBACK:-gfx942;gfx950}"
            echo "Building for default multi-arch fat binary: ${CUOPT_CMAKE_GPU_ARCHITECTURES}"
        fi
    fi
    ARCH_CMAKE_VAR="CMAKE_HIP_ARCHITECTURES"
else
    # CUDA GPU architectures
    if  [ ${BUILD_ALL_GPU_ARCH} -eq 1 ]; then
        CUOPT_CMAKE_GPU_ARCHITECTURES="RAPIDS"
        echo "Building for *ALL* supported NVIDIA GPU architectures..."
    elif [ ${BUILD_CI_ONLY} -eq 1 ]; then
        CUOPT_CMAKE_GPU_ARCHITECTURES="RAPIDS"
        echo "Building for RAPIDS supported architectures..."
    else
        CUOPT_CMAKE_GPU_ARCHITECTURES="NATIVE"
        echo "Building for the architecture of the NVIDIA GPU in the system..."
    fi
    ARCH_CMAKE_VAR="CMAKE_CUDA_ARCHITECTURES"
fi

################################################################################
# Configure, build, and install libmps_parser
if buildAll || hasArg libmps_parser; then
    mkdir -p "${LIBMPS_PARSER_BUILD_DIR}"
    cd "${LIBMPS_PARSER_BUILD_DIR}"
    cmake -DDEFINE_ASSERT=${DEFINE_ASSERT} \
          -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
          -DUSE_ROCM=${USE_ROCM} \
          -DCPM_DOWNLOAD_ALL=ON \
          "${CACHE_ARGS[@]}" \
          "${REPODIR}"/cpp/libmps_parser/

    if hasArg -n; then
        cmake --build "${LIBMPS_PARSER_BUILD_DIR}" ${VERBOSE_FLAG}
    else
        cmake --build "${LIBMPS_PARSER_BUILD_DIR}" --target ${INSTALL_TARGET} ${VERBOSE_FLAG}
    fi
fi

################################################################################
# Configure, build, and install libcuopt
if buildAll || hasArg libcuopt; then
    mkdir -p "${LIBCUOPT_BUILD_DIR}"
    cd "${LIBCUOPT_BUILD_DIR}"
    
    # The main CMakeLists.txt now supports both CUDA and ROCm via USE_ROCM flag
    if [ ${USE_ROCM} -eq 1 ]; then
        echo "Building for ROCm (USE_ROCM=1)"
        echo "CMakeLists.txt will use ROCm-DS rapids-cmake and amdclang++"
    else
        echo "Building for CUDA (USE_ROCM=0)"
    fi
    
    cmake -DDEFINE_ASSERT=${DEFINE_ASSERT} \
          -DDEFINE_BENCHMARK="${DEFINE_BENCHMARK}" \
          -DBUILD_LP_BENCHMARKS="${DEFINE_BENCHMARK}" \
          -DDEFINE_PDLP_VERBOSE_MODE=${DEFINE_PDLP_VERBOSE_MODE} \
          -DLIBCUOPT_LOGGING_LEVEL="${LOGGING_ACTIVE_LEVEL}" \
          -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
          -D${ARCH_CMAKE_VAR}=${CUOPT_CMAKE_GPU_ARCHITECTURES} \
          -DDISABLE_DEPRECATION_WARNING=${BUILD_DISABLE_DEPRECATION_WARNING} \
          -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
          -DUSE_ROCM=${USE_ROCM} \
          -DFETCH_RAPIDS=${FETCH_RAPIDS} \
          -DBUILD_LP_ONLY=${BUILD_LP_ONLY} \
          -DBUILD_SANITIZER=${BUILD_SANITIZER} \
          -DBUILD_TSAN=${BUILD_TSAN} \
          -DBUILD_MSAN=${BUILD_MSAN} \
          -DSKIP_C_PYTHON_ADAPTERS=${SKIP_C_PYTHON_ADAPTERS} \
          -DBUILD_TESTS=$((1 - ${SKIP_TESTS_BUILD})) \
          -DSKIP_ROUTING_BUILD=${SKIP_ROUTING_BUILD} \
          -DWRITE_FATBIN=${WRITE_FATBIN} \
          -DHOST_LINEINFO=${HOST_LINEINFO} \
          -DINSTALL_TARGET="${INSTALL_TARGET}" \
          -DCPM_DOWNLOAD_ALL=ON \
          "${CACHE_ARGS[@]}" \
          "${EXTRA_CMAKE_ARGS[@]}" \
          "${REPODIR}"/cpp
          
    if hasArg -n; then
        cmake --build "${LIBCUOPT_BUILD_DIR}" ${VERBOSE_FLAG}
    else
        # Build the default `all` target first, then install.  We can't rely on
        # `--target install` alone to compile the gtest executables: their
        # install rules are EXCLUDE_FROM_ALL (see cpp/tests/CMakeLists.txt), so
        # the install target never builds them.  Building `all` compiles the
        # library AND the test executables (the latter only exist when
        # BUILD_TESTS=ON, i.e. when --skip-tests-build was NOT passed).
        cmake --build "${LIBCUOPT_BUILD_DIR}" ${VERBOSE_FLAG} -j"${PARALLEL_LEVEL}"
        cmake --build "${LIBCUOPT_BUILD_DIR}" --target ${INSTALL_TARGET} ${VERBOSE_FLAG} -j"${PARALLEL_LEVEL}"
        # Install the EXCLUDE_FROM_ALL `testing` component so the gtest binaries
        # land in <prefix>/bin/gtests/libcuopt, where the test driver looks.
        if [ "${SKIP_TESTS_BUILD}" -eq 0 ]; then
            cmake --install "${LIBCUOPT_BUILD_DIR}" --component testing
        fi
    fi
fi

################################################################################
# Build deb package
if hasArg deb; then
    if [ ! -d "${LIBCUOPT_BUILD_DIR}" ]; then
        echo "Error: libcuopt must be built before creating deb package. Run with 'libcuopt' target first."
        exit 1
    fi

    echo "Building deb package..."
    cd "${LIBCUOPT_BUILD_DIR}"
    cpack -G DEB
    echo "Deb package created in ${LIBCUOPT_BUILD_DIR}"
fi

# scikit-build-core splits SKBUILD_CMAKE_ARGS on ';'.  Write the GPU arch list to a
# CMake initial-cache file so multi-arch values like gfx942;gfx950 are not split.
if buildAll || hasArg cuopt || hasArg cuopt_mps_parser; then
    SKBUILD_ARCH_CACHE=$(mktemp --suffix=.cmake)
    # -C expects a CMake script (set ... CACHE), not CMakeCache.txt VAR:TYPE=value syntax.
    printf 'set(%s "%s" CACHE STRING "" FORCE)\n' "${ARCH_CMAKE_VAR}" "${CUOPT_CMAKE_GPU_ARCHITECTURES}" > "${SKBUILD_ARCH_CACHE}"
    SKBUILD_CMAKE_ARGS="-C ${SKBUILD_ARCH_CACHE};-DCMAKE_PREFIX_PATH=${INSTALL_PREFIX};-DCMAKE_LIBRARY_PATH=${LIBCUOPT_BUILD_DIR};-DUSE_ROCM=${USE_ROCM};${EXTRA_CMAKE_ARGS[*]// /;}"
fi

# Build and install the libcuopt Python package (runtime loader for libcuopt.so).
# This must come BEFORE cuopt because cuopt/__init__.py does 'import libcuopt'.
if buildAll || hasArg cuopt; then
    cd "${REPODIR}"/python/libcuopt

    SKBUILD_CMAKE_ARGS="${SKBUILD_CMAKE_ARGS}" \
        python "${PYTHON_ARGS_FOR_INSTALL[@]}" .
fi

# Build and install the cuopt Python package
if buildAll || hasArg cuopt; then
    cd "${REPODIR}"/python/cuopt

    SKBUILD_CMAKE_ARGS="${SKBUILD_CMAKE_ARGS}" \
        python "${PYTHON_ARGS_FOR_INSTALL[@]}" .
fi

# Build and install the cuopt MPS parser Python package
if buildAll || hasArg cuopt_mps_parser; then
    cd "${REPODIR}"/python/cuopt/cuopt/linear_programming

    SKBUILD_CMAKE_ARGS="${SKBUILD_CMAKE_ARGS}" \
        python "${PYTHON_ARGS_FOR_INSTALL[@]}" .
fi

# Build and install the cuopt_server Python package
if buildAll || hasArg cuopt_server; then
    cd "${REPODIR}"/python/cuopt_server
    python "${PYTHON_ARGS_FOR_INSTALL[@]}" .
fi

# Build and install the cuopt_sh_client Python package
if buildAll || hasArg cuopt_sh_client; then
    cd "${REPODIR}"/python/cuopt_self_hosted/
    python "${PYTHON_ARGS_FOR_INSTALL[@]}" .
fi

# Build the docs
if buildAll || hasArg docs; then
    # Ensure ROCm Data Science packages are present for the Sphinx docs build.
    # The cuopt pip installs above may trigger resolution that replaces amd-cupy
    # with the NVIDIA cupy-cuda13x stub; reinstall here to guarantee correctness.
    if [ ${USE_ROCM} -eq 1 ]; then
        pip install --force-reinstall amd-hipdf==3.0.0 --extra-index-url="${AMD_PYPI_INDEX}"
        pip install rocm-docs-core

        # numba-hip expects a specific Clang version directory under /opt/rocm/llvm/.
        # When the installed numba-hip was built for a different ROCm release, the
        # expected Clang directory may not exist (e.g. numba-hip from rocm-7.0.2
        # looks for Clang 20, but ROCm 7.2 ships Clang 22).  Create a compatibility
        # symlink so the import succeeds on any ROCm 7.x version.
        ACTUAL_CLANG_DIR=$(ls -d /opt/rocm/llvm/lib/clang/[0-9]* 2>/dev/null | head -1)
        if [ -n "${ACTUAL_CLANG_DIR}" ]; then
            for expected in 18 19 20 21 22 23; do
                target="/opt/rocm/llvm/lib/clang/${expected}"
                if [ ! -e "${target}" ] && [ ! -L "${target}" ]; then
                    ln -sf "${ACTUAL_CLANG_DIR}" "${target}" 2>/dev/null || true
                fi
            done
        fi
    fi

    cd "${REPODIR}"/cpp/doxygen
    doxygen Doxyfile

    cd "${REPODIR}"/docs/cuopt
    make clean
    make html linkcheck
fi

# Print summary
echo ""
echo "========================================"
if [ ${USE_ROCM} -eq 1 ]; then
    echo "ROCm Build Complete!"
    echo "========================================"
    echo "Platform: AMD ROCm"
    echo "GPU Architectures: ${CUOPT_CMAKE_GPU_ARCHITECTURES}"
else
    echo "CUDA Build Complete!"
    echo "========================================"
    echo "Platform: NVIDIA CUDA"
    echo "GPU Architectures: ${CUOPT_CMAKE_GPU_ARCHITECTURES}"
fi
echo "Build Type: ${BUILD_TYPE}"
echo "Install Prefix: ${INSTALL_PREFIX}"
echo "========================================"
