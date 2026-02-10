# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2021-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: ROCm port modifications (c) 2026
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

cmake_minimum_required(VERSION 3.22 FATAL_ERROR)

# Detect platform: CUDA or ROCm BEFORE project() call
set(USE_ROCM ON CACHE BOOL "Build with ROCm instead of CUDA")

if(USE_ROCM)
    message(STATUS "Building for ROCm/HIP platform")
    
    # Set ROCM_PATH early
    if(NOT DEFINED ROCM_PATH)
        if(DEFINED ENV{ROCM_PATH})
            set(ROCM_PATH $ENV{ROCM_PATH} CACHE PATH "Path to ROCm installation")
        else()
            # Try common ROCm installation paths
            if(EXISTS "/opt/rocm-7.1.1")
                set(ROCM_PATH "/opt/rocm-7.1.1" CACHE PATH "Path to ROCm installation")
            elseif(EXISTS "/opt/rocm")
                set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to ROCm installation")
            else()
                set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to ROCm installation")
            endif()
        endif()
    endif()
    
    # CRITICAL: Set HIP compiler BEFORE FetchContent/project()
    # Use amdclang++ (ROCm 7.x native compiler) which has built-in ROCm awareness
    if(EXISTS "${ROCM_PATH}/bin/amdclang++")
        set(CMAKE_HIP_COMPILER "${ROCM_PATH}/bin/amdclang++" CACHE FILEPATH "HIP compiler")
        set(CMAKE_CXX_COMPILER "${ROCM_PATH}/bin/amdclang++" CACHE FILEPATH "CXX compiler")
        set(CMAKE_C_COMPILER "${ROCM_PATH}/bin/amdclang" CACHE FILEPATH "C compiler")
        message(STATUS "Using amdclang++ (ROCm 7.x native compiler)")
    elseif(EXISTS "${ROCM_PATH}/bin/hipcc")
        set(CMAKE_HIP_COMPILER "${ROCM_PATH}/bin/hipcc" CACHE FILEPATH "HIP compiler")
        message(STATUS "Using hipcc (fallback)")
    else()
        message(FATAL_ERROR "Could not find amdclang++ or hipcc in ${ROCM_PATH}/bin/")
    endif()
    
    set(CMAKE_HIP_COMPILER_ROCM_ROOT "${ROCM_PATH}" CACHE PATH "ROCm root for HIP compiler")
    
    # Set CMAKE_PREFIX_PATH EARLY so rapids-cmake can find ROCm libraries
    list(APPEND CMAKE_PREFIX_PATH 
        ${ROCM_PATH}
        ${ROCM_PATH}/lib/cmake
        ${ROCM_PATH}/hip
        ${ROCM_PATH}/lib/cmake/hip
        ${ROCM_PATH}/lib/cmake/hip-lang
    )
    
    # Add individual library CMake config locations
    foreach(lib IN ITEMS hipblas hipsparse hiprand hipsolver rocthrust hipcub rocprim)
        if(EXISTS "${ROCM_PATH}/lib/cmake/${lib}")
            list(APPEND CMAKE_PREFIX_PATH "${ROCM_PATH}/lib/cmake/${lib}")
        endif()
    endforeach()
    
    list(APPEND CMAKE_MODULE_PATH ${ROCM_PATH}/lib/cmake/hip)
    
    message(STATUS "CMAKE_PREFIX_PATH set before ROCm-DS: ${CMAKE_PREFIX_PATH}")
    
    # ROCm-DS rapids-cmake integration using FetchContent
    # Use HTTPS with credentials from environment variables
    # Set: export GH_USERNAME=your_github_username
    #      export GH_TOKEN=your_personal_access_token
    include(FetchContent)
    
    # Construct URL with credentials if provided
    if(DEFINED ENV{GH_USERNAME} AND DEFINED ENV{GH_TOKEN})
        set(RAPIDS_CMAKE_REPO "https://$ENV{GH_USERNAME}:$ENV{GH_TOKEN}@github.com/AMD-AIOSS/ROCmDS-cmake.git")
        message(STATUS "Using authenticated HTTPS access to AMD-AIOSS/ROCmDS-cmake")
    else()
        # Fallback to unauthenticated (will fail for private repos)
        set(RAPIDS_CMAKE_REPO "https://github.com/AMD-AIOSS/ROCmDS-cmake.git")
        message(WARNING "GH_USERNAME and/or GH_TOKEN not set - clone may fail for private repo")
    endif()
    
    FetchContent_Declare(
      rapids-cmake
      GIT_REPOSITORY ${RAPIDS_CMAKE_REPO}
      GIT_TAG feat/upgrade_to_25.10
    )
    FetchContent_MakeAvailable(rapids-cmake)
    
    # Include ROCm-DS RAPIDS modules
    include(${rapids-cmake_SOURCE_DIR}/RAPIDS.cmake)
    include(rapids-cmake)
    include(rapids-cpm)
    include(rapids-hip)
    include(rapids-export)
    include(rapids-find)
    
    message(STATUS "Using ROCm-DS rapids-cmake from GitHub")
    
    # CMAKE_PREFIX_PATH was already set above before FetchContent
    # Just confirm it's still set
    message(STATUS "CMAKE_PREFIX_PATH after ROCm-DS load: ${CMAKE_PREFIX_PATH}")
    
    list(APPEND CMAKE_MODULE_PATH ${ROCM_PATH}/lib/cmake/hip)
    
    # Initialize HIP architectures using ROCm-DS rapids-hip
    include(${rapids-cmake_SOURCE_DIR}/rapids-cmake/hip/init_architectures.cmake)
    rapids_hip_init_architectures(CUOPT)
    
else()
    message(STATUS "Building for NVIDIA CUDA platform")
    
    # Original CUDA configuration
    set(RAFT_NVTX ON)
    include(../cmake/rapids_config.cmake)
    include(rapids-cmake)
    include(rapids-cpm)
    include(rapids-cuda)
    include(rapids-export)
    include(rapids-find)
    
    rapids_cuda_init_architectures(CUOPT)
endif()

# Project declaration - MUST come early to enable languages
if(USE_ROCM)
    project(
      CUOPT
      VERSION "26.01.0"
      LANGUAGES CXX C HIP
    )
else()
    project(
      CUOPT
      VERSION "${RAPIDS_VERSION}"
      LANGUAGES CXX CUDA C
    )
endif()

# Add our custom Find modules to the module path
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/thirdparty")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
message(STATUS "CMAKE_MODULE_PATH = ${CMAKE_MODULE_PATH}")

include(GNUInstallDirs)

# Disable C++20 module scanning as the codebase doesn't use modules
set(CMAKE_CXX_SCAN_FOR_MODULES OFF CACHE BOOL "Disable C++20 module scanning")

# For ROCm: Tell CMake to treat .cu files as HIP source files
if(USE_ROCM)
    set_source_files_properties(
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        PROPERTIES LANGUAGE HIP
    )
    # Enable .cu files to be compiled as HIP
    set(CMAKE_HIP_SOURCE_FILE_EXTENSIONS cu cuh)
    message(STATUS "Configured CMake to treat .cu files as HIP sources")
endif()

# Now find HIP packages (after project() enables languages)
if(USE_ROCM)
    # ROCM_PATH should already be set from earlier, but double-check
    if(NOT DEFINED ROCM_PATH)
        if(DEFINED ENV{ROCM_PATH})
            set(ROCM_PATH $ENV{ROCM_PATH})
        else()
            # Try common ROCm installation paths (same as earlier)
            if(EXISTS "/opt/rocm-7.1.1")
                set(ROCM_PATH "/opt/rocm-7.1.1")
            elseif(EXISTS "/opt/rocm")
                set(ROCM_PATH "/opt/rocm")
            else()
                set(ROCM_PATH "/opt/rocm")
            endif()
        endif()
    endif()
    
    message(STATUS "Finding ROCm packages with ROCM_PATH: ${ROCM_PATH}")
    
    # Ensure ROCM_PATH is in CMAKE_PREFIX_PATH 
    message(STATUS "Current CMAKE_PREFIX_PATH: ${CMAKE_PREFIX_PATH}")
    
    # Use regular find_package - rapids_find_package might not support these
    find_package(hip REQUIRED)
    find_package(hipblas REQUIRED)
    find_package(hipsparse REQUIRED)
    find_package(hiprand REQUIRED)
    find_package(hipsolver REQUIRED)
    find_package(rocthrust REQUIRED)
    find_package(hipcub REQUIRED)
    find_package(rocprim REQUIRED)
    
    # Promote ROCm imported targets to global scope NOW (in the directory that
    # created them).  Without this, hipccl-config.cmake — which runs from the
    # RMM subdirectory scope (build/_deps/rmm-src/) — fails with:
    #   "Attempt to promote imported target ... to global scope ... which is
    #    not built in this directory."
    # Once global, the redundant set_target_properties(IMPORTED_GLOBAL TRUE) in
    # hipccl-dependencies.cmake becomes a harmless no-op.
    foreach(_rocm_tgt roc::rocprim roc::rocprim_hip hip::hipcub roc::rocthrust)
        if(TARGET ${_rocm_tgt})
            get_target_property(_is_global ${_rocm_tgt} IMPORTED_GLOBAL)
            if(NOT _is_global)
                set_target_properties(${_rocm_tgt} PROPERTIES IMPORTED_GLOBAL TRUE)
            endif()
        endif()
    endforeach()
    
    message(STATUS "✓ HIP version: ${hip_VERSION}")
    message(STATUS "✓ ROCm path: ${ROCM_PATH}")
    
    # Ensure ROCm library directory is in the linker search path globally.
    # HIP-linked targets get this automatically via --hip-link, but plain CXX
    # targets (e.g. C_API_TEST) need it explicitly for -lhipblas etc.
    link_directories(${ROCM_PATH}/lib)
endif()

if(USE_ROCM)
    # Write ROCm version file
    set(VERSION_MAJOR 26)
    set(VERSION_MINOR 01)
    set(VERSION_PATCH 0)
    configure_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/include/cuopt/version_config.hpp.in
        ${CMAKE_CURRENT_BINARY_DIR}/include/cuopt/version_config.hpp
        @ONLY
    )
else()
    rapids_cmake_write_version_file(include/cuopt/version_config.hpp)
endif()

# ##################################################################################################
# - build type ------------------------------------------------------------------------------------

# Set a default build type if none was specified
if(USE_ROCM)
    if(NOT CMAKE_BUILD_TYPE)
        set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
    endif()
else()
    rapids_cmake_build_type(Release)
endif()

# #############################################################################
# - User Options  ------------------------------------------------------------
if(USE_ROCM)
    option(CMAKE_HIP_LINEINFO "Enable line info for HIP useful for profiling" ON)
else()
    option(CMAKE_CUDA_LINEINFO "Enable the -lineinfo option for nvcc useful for cuda-memcheck / profiler" ON)
endif()

option(BUILD_TESTS "Configure CMake to build tests" ON)
option(DISABLE_OPENMP "Disable OpenMP" OFF)
option(BUILD_LP_ONLY "Build only linear programming components, exclude routing and MIP-specific files" OFF)
option(SKIP_C_PYTHON_ADAPTERS "Skip building C and Python adapter files (cython_solve.cu and cuopt_c.cpp)" OFF)
option(SKIP_ROUTING_BUILD "Skip building routing components" OFF)
option(WRITE_FATBIN "Enable fatbin writing" ON)
option(HOST_LINEINFO "Build with debug line information for host code" OFF)

if(USE_ROCM)
    message(VERBOSE "cuOpt: Enable HIP line info: ${CMAKE_HIP_LINEINFO}")
else()
    message(VERBOSE "cuOpt: Enable nvcc -lineinfo: ${CMAKE_CUDA_LINEINFO}")
endif()

message(VERBOSE "Build unit-tests: ${BUILD_TESTS}")
message(VERBOSE "Disable OpenMP: ${DISABLE_OPENMP}")
message(VERBOSE "Build LP-only mode: ${BUILD_LP_ONLY}")
message(VERBOSE "Skip C/Python adapters: ${SKIP_C_PYTHON_ADAPTERS}")
message(VERBOSE "Skip routing build: ${SKIP_ROUTING_BUILD}")
message(VERBOSE "Build with debug line information for host code: ${HOST_LINEINFO}")
message(VERBOSE "fatbin: ${WRITE_FATBIN}")

# ##################################################################################################
# - compiler options ------------------------------------------------------------------------------

if(NOT USE_ROCM)
    # CUDA runtime
    rapids_cuda_init_runtime(USE_STATIC ON)
    
    rapids_find_package(CUDAToolkit REQUIRED
      BUILD_EXPORT_SET cuopt-exports
      INSTALL_EXPORT_SET cuopt-exports
    )
endif()

set(CUOPT_CXX_FLAGS "")
if(USE_ROCM)
    set(CUOPT_HIP_FLAGS "")
else()
    set(CUOPT_CUDA_FLAGS "")
endif()

if(CMAKE_COMPILER_IS_GNUCXX)
  list(APPEND CUOPT_CXX_FLAGS -Werror -Wno-error=deprecated-declarations)
endif(CMAKE_COMPILER_IS_GNUCXX)

# Sanitizer support
if(BUILD_SANITIZER)
  list(APPEND CUOPT_CXX_FLAGS -fsanitize=address,undefined -fno-omit-frame-pointer -g)
  if(NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
    list(APPEND CUOPT_CXX_FLAGS -Wno-error=maybe-uninitialized)
  endif()
  add_link_options(-fsanitize=address,undefined)
endif(BUILD_SANITIZER)

if(BUILD_TSAN)
  message(STATUS "Building with ThreadSanitizer enabled")
  list(APPEND CUOPT_CXX_FLAGS -fsanitize=thread -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=thread)
endif(BUILD_TSAN)

if(BUILD_MSAN)
  message(STATUS "Building with MemorySanitizer enabled")
  list(APPEND CUOPT_CXX_FLAGS -fsanitize=memory -fno-omit-frame-pointer -g -fsanitize-memory-track-origins=1)
  add_link_options(-fsanitize=memory)
endif(BUILD_MSAN)

if(DEFINE_ASSERT)
  add_definitions(-DASSERT_MODE)
endif(DEFINE_ASSERT)

if(DEFINE_BENCHMARK)
  add_definitions(-DBENCHMARK)
endif(DEFINE_BENCHMARK)

if(DEFINE_PDLP_VERBOSE_MODE)
  add_definitions(-DPDLP_VERBOSE_MODE)
endif(DEFINE_PDLP_VERBOSE_MODE)

# Set logging level
set(LIBCUOPT_LOGGING_LEVEL
  "INFO"
  CACHE STRING "Choose the logging level."
)
set_property(
  CACHE LIBCUOPT_LOGGING_LEVEL PROPERTY STRINGS "TRACE" "DEBUG" "INFO" "WARN" "ERROR" "CRITICAL"
                                       "OFF")
message(VERBOSE "LIBCUOPT_LOGGING_LEVEL = '${LIBCUOPT_LOGGING_LEVEL}'.")

message("-- Building with logging level = ${LIBCUOPT_LOGGING_LEVEL}")

if(USE_ROCM)
    # HIP architecture configuration
    if(NOT DEFINED CMAKE_HIP_ARCHITECTURES)
        set(CMAKE_HIP_ARCHITECTURES "gfx90a;gfx908;gfx942" CACHE STRING "HIP architectures")
    endif()
    message("-- Building for HIP_ARCHS = '${CMAKE_HIP_ARCHITECTURES}'")
    
    # HIP compiler flags
    set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -fgpu-rdc")
    list(APPEND CUOPT_HIP_FLAGS 
        -Wno-deprecated-declarations
        -fopenmp
        -fPIC
    )
    
    # Add ROCm-specific defines
    add_definitions(-D__HIP_PLATFORM_AMD__)
    add_definitions(-DUSE_ROCM)
else()
    message("-- Building for GPU_ARCHS = '${CMAKE_CUDA_ARCHITECTURES}'")
    
    # CUDA compiler flags
    set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} --expt-relaxed-constexpr --expt-extended-lambda")
    if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 12.9)
      set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -static-global-template-stub=false")
    endif()
    list(APPEND CUOPT_CUDA_FLAGS -Werror=cross-execution-space-call -Wno-deprecated-declarations -Xcompiler=-Werror --default-stream=per-thread)
    if("${CMAKE_CUDA_HOST_COMPILER}" MATCHES "clang" OR "${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
      list(APPEND CUOPT_CUDA_FLAGS -Xcompiler=-Wall)
    else()
      list(APPEND CUOPT_CUDA_FLAGS -Xcompiler=-Wall -Wno-error=non-template-friend)
    endif()
    list(APPEND CUOPT_CUDA_FLAGS -Xfatbin=-compress-all)
    if(CMAKE_CUDA_COMPILER_VERSION VERSION_GREATER_EQUAL 12.9 AND CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 13.0)
      list(APPEND CUOPT_CUDA_FLAGS -Xfatbin=--compress-level=3)
    endif()
    list(APPEND CUOPT_CUDA_FLAGS -fopenmp)
endif()

message("-- Host target architecture = '${CMAKE_SYSTEM_PROCESSOR}'")

if(NOT DISABLE_OPENMP)
  find_package(OpenMP)

  if(OPENMP_FOUND)
    message(VERBOSE "OpenMP found in ${OpenMP_CXX_INCLUDE_DIRS}")
  endif()
endif()

# Debug options
if(CMAKE_BUILD_TYPE MATCHES Debug)
  message(STATUS "Building with debugging flags")
  if(USE_ROCM)
    list(APPEND CUOPT_HIP_FLAGS -g -O0)
  else()
    list(APPEND CUOPT_CUDA_FLAGS -G -Xcompiler=-rdynamic -O0)
  endif()
# Option to enable line info
elseif(USE_ROCM AND CMAKE_HIP_LINEINFO)
  message(STATUS "Enabling HIP line info")
  list(APPEND CUOPT_HIP_FLAGS -gline-tables-only)
elseif(CMAKE_CUDA_LINEINFO)
  message(STATUS "Enabling CUDA line info")
  list(APPEND CUOPT_CUDA_FLAGS -lineinfo)
  set(CMAKE_CUDA_FLAGS_RELEASE "${CMAKE_CUDA_FLAGS_RELEASE} -lineinfo")
endif(CMAKE_BUILD_TYPE MATCHES Debug)

# Undefine NDEBUG if assert mode is on
if(DEFINE_ASSERT)
  message(STATUS "Undefining NDEBUG with assert mode enabled")
  add_definitions(-UNDEBUG)
endif()

# CRITICAL: For ROCm, suppress warnings and handle compatibility
if(USE_ROCM)
  # Suppress deprecated literal operator warning from fmt library
  add_definitions(-Wno-deprecated-literal-operator)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-deprecated-literal-operator")
  set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -Wno-deprecated-literal-operator")
  list(APPEND CUOPT_CXX_FLAGS -Wno-deprecated-literal-operator)
  list(APPEND CUOPT_HIP_FLAGS -Wno-deprecated-literal-operator)
  
  # Workaround: Force-include <cstring> so that the standard host memset is visible
  # before rocprim's texture_cache_iterator.hpp tries to call it (otherwise only the
  # __device__ overload from HIP is found, causing a compile error).
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -include cstring")
  set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -include cstring")
  
  # Ensure the ROCm library directory is in the linker search path for ALL targets.
  # HIP-linked executables get this via --hip-link, but plain CXX executables
  # (e.g. C_API_TEST) need it explicitly to resolve -lhipblas, -lhipsparse, etc.
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -L${ROCM_PATH}/lib")
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -L${ROCM_PATH}/lib")
  
  message(STATUS "✅ Suppressed deprecated-literal-operator warnings from fmt library")
  message(STATUS "✅ RAFT's mdspan will be patched to skip std::assume_aligned after fetch")
endif()

# ##################################################################################################
# - find CPM based dependencies  ------------------------------------------------------------------

if(USE_ROCM)
    # ROCm-DS RAPIDS dependencies
    rapids_cpm_init()
    rapids_cmake_install_lib_dir(lib_dir)
    
    message(STATUS "Using ROCm-DS rapids modules for dependencies")
    
    # === PLAIN spdlog: Just use rapids_logger like NVIDIA ===
    # CRITICAL: Disable C++20 std::format auto-detection in spdlog
    # spdlog auto-detects C++20 and tries to use std::format, but then has namespace confusion
    set(SPDLOG_USE_STD_FORMAT OFF CACHE BOOL "Force spdlog to use fmt library, not std::format" FORCE)
    message(STATUS "🔧 SPDLOG_USE_STD_FORMAT=OFF (forcing fmt library usage)")
    
    include(${rapids-cmake_SOURCE_DIR}/rapids-cmake/cpm/rocmds_logger.cmake)
    rapids_cpm_rapids_logger()
    
    # Use spdlog with BUNDLED fmt to avoid compatibility issues with system/conda fmt 12.0+
    # fmt 11+ moved basic_format_string from core.h to base.h, breaking older spdlog versions
    include(${rapids-cmake_SOURCE_DIR}/rapids-cmake/cpm/spdlog.cmake)
    rapids_cpm_spdlog(FMT_OPTION "BUNDLED" 
                      BUILD_EXPORT_SET cuopt-exports 
                      INSTALL_EXPORT_SET cuopt-exports)
    message(STATUS "✅ spdlog fetched with bundled fmt")
    
    rapids_make_logger(rapids_logger
        EXPORT_SET cuopt-exports
        LOGGER_DEFAULT_LEVEL INFO
        LOGGER_HEADER_DIR include/rapids_logger
    )
    message(STATUS "✅ rapids_logger configured")
    
    # CRITICAL FIX: Patch spdlog/common.h AFTER fetch (rapids_make_logger fetches spdlog internally)
    # Even though SPDLOG_USE_STD_FORMAT=OFF, the header still includes <format> which pollutes namespace
    set(SPDLOG_COMMON_H "${CMAKE_CURRENT_BINARY_DIR}/_deps/spdlog-src/include/spdlog/common.h")
    if(EXISTS "${SPDLOG_COMMON_H}")
        message(STATUS "🔧 Patching spdlog/common.h to prevent C++20 <format> inclusion...")
        file(READ "${SPDLOG_COMMON_H}" SPDLOG_COMMON_CONTENT)
        
        # Check if already patched
        string(FIND "${SPDLOG_COMMON_CONTENT}" "ROCM PATCH" ALREADY_PATCHED)
        if(ALREADY_PATCHED EQUAL -1)
            # Replace ALL occurrences: #ifdef SPDLOG_USE_STD_FORMAT with #if 0
            string(REPLACE 
                "#ifdef SPDLOG_USE_STD_FORMAT"
                "// ROCM PATCH: Never use C++20 std::format - always use bundled fmt\n#if 0 /* Original: #ifdef SPDLOG_USE_STD_FORMAT */"
                SPDLOG_COMMON_PATCHED "${SPDLOG_COMMON_CONTENT}")
            
            file(WRITE "${SPDLOG_COMMON_H}" "${SPDLOG_COMMON_PATCHED}")
            message(STATUS "✅ spdlog/common.h patched - <format> will never be included")
        else()
            message(STATUS "✅ spdlog/common.h already patched")
        endif()
    else()
        message(WARNING "⚠️ spdlog/common.h not found at ${SPDLOG_COMMON_H} - patch skipped (may be using system spdlog)")
    endif()
    
    # Generate logger macros for cuopt
    if(COMMAND rapids_make_logger_macros)
        rapids_make_logger_macros(CUOPT "cuopt::default_logger()" include/cuopt)
        message(STATUS "✅ Generated logger macros for cuopt")
    else()
        # Fallback: Create logger macros manually
        message(STATUS "Creating logger_macros.hpp manually")
        file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/cuopt")
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/include/cuopt/logger_macros.hpp"
"// Auto-generated logger macros for ROCm
#pragma once
#include <spdlog/spdlog.h>

#define CUOPT_LOG_TRACE(...) cuopt::default_logger().trace(__VA_ARGS__)
#define CUOPT_LOG_DEBUG(...) cuopt::default_logger().debug(__VA_ARGS__)
#define CUOPT_LOG_INFO(...) cuopt::default_logger().info(__VA_ARGS__)
#define CUOPT_LOG_WARN(...) cuopt::default_logger().warn(__VA_ARGS__)
#define CUOPT_LOG_ERROR(...) cuopt::default_logger().error(__VA_ARGS__)
#define CUOPT_LOG_CRITICAL(...) cuopt::default_logger().critical(__VA_ARGS__)
")
        message(STATUS "✅ Created logger_macros.hpp")
    endif()
    
    find_package(TBB REQUIRED)
    
    # Papilo for presolve - use local patched version with fmt 10.x compatibility
    # The patch is in Message.hpp to support fmt 10.x make_format_args lvalue requirement
    set(PAPILO_PATCHED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../papilo_patched")
    if(EXISTS "${PAPILO_PATCHED_DIR}")
        message(STATUS "Using local patched papilo from ${PAPILO_PATCHED_DIR}")
        FetchContent_Declare(
          papilo
          SOURCE_DIR "${PAPILO_PATCHED_DIR}"
          EXCLUDE_FROM_ALL
          SYSTEM
        )
    else()
        message(STATUS "Local patched papilo not found, fetching from GitHub")
        FetchContent_Declare(
          papilo
          GIT_REPOSITORY "https://github.com/scipopt/papilo.git"
          GIT_TAG "741a2b9c8155b249d6df574d758b4d97d4417520"
          GIT_PROGRESS TRUE
          EXCLUDE_FROM_ALL
          SYSTEM
        )
    endif()
    
    set(BUILD_TESTING OFF CACHE BOOL "Disable test build for papilo")
    set(PAPILO_NO_BINARIES ON)
    option(LUSOL "Disable LUSOL" OFF)
    
    FetchContent_MakeAvailable(papilo)
    
    # Note: papilo fmt headers are already patched in the local papilo_patched directory
    # The patches include: redirect all fmt headers to spdlog's bundled fmt,
    # and Message.hpp fix for fmt 10.x enum formatting
    message(STATUS "✅ Using local patched papilo with fmt 10.x compatibility")
    
    # Note: CUDSS has no ROCm equivalent
    message(STATUS "CUDSS not available for ROCm - sparse direct solver features will be limited")
    
    # Use hipRAFT and RMM from ROCm-DS
    # IMPORTANT: Configure RMM first, then RAFT (RAFT depends on RMM)
    include(cmake/thirdparty/get_rmm.cmake)
    include(cmake/thirdparty/get_raft.cmake)
    
    # Call functions in correct order: RMM first, then RAFT
    find_and_configure_rmm()
    find_and_configure_raft(VERSION  0.1.0
            FORK                     ROCm-DS
            PINNED_TAG               release/rocmds-25.10
            COMPILE_LIBRARY          OFF
            ENABLE_MNMG_DEPENDENCIES OFF
    )
    
    message(STATUS "✓ RAFT and RMM configured via ROCm-DS")
    
    # Resolve the RAFT include root.  rapids_cpm_find / CPM sets
    # raft_SOURCE_DIR after downloading.  Depending on CPM version and
    # SOURCE_SUBDIR, it may point to the repo root or to the "cpp" subdir.
    # We try both to be robust.
    set(_RAFT_INCLUDE_ROOT "")
    if(DEFINED raft_SOURCE_DIR)
        if(EXISTS "${raft_SOURCE_DIR}/include/raft/cuda_runtime.h")
            # raft_SOURCE_DIR already points to the cpp subdirectory
            set(_RAFT_INCLUDE_ROOT "${raft_SOURCE_DIR}/include")
        elseif(EXISTS "${raft_SOURCE_DIR}/cpp/include/raft/cuda_runtime.h")
            # raft_SOURCE_DIR points to the repo root
            set(_RAFT_INCLUDE_ROOT "${raft_SOURCE_DIR}/cpp/include")
        endif()
    endif()
    # Fallback: try the default FetchContent path
    if(NOT _RAFT_INCLUDE_ROOT)
        if(EXISTS "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include/raft/cuda_runtime.h")
            set(_RAFT_INCLUDE_ROOT "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include")
        endif()
    endif()
    
    if(_RAFT_INCLUDE_ROOT)
        message(STATUS "RAFT include root resolved to: ${_RAFT_INCLUDE_ROOT}")
    else()
        message(WARNING "⚠️ Could not resolve RAFT include root (raft_SOURCE_DIR=${raft_SOURCE_DIR}) - patching will be skipped")
    endif()
    
    # CRITICAL FIX: Patch RAFT's mdspan to skip std::assume_aligned on ROCm
    # This is cleaner than force-including a header
    set(ALIGNED_ACCESSOR_FILE "${_RAFT_INCLUDE_ROOT}/raft/thirdparty/mdspan/include/experimental/__p0009_bits/aligned_accessor.hpp")
    if(_RAFT_INCLUDE_ROOT AND EXISTS "${ALIGNED_ACCESSOR_FILE}")
        file(READ "${ALIGNED_ACCESSOR_FILE}" ACCESSOR_CONTENT)
        
        # Check if already patched
        string(FIND "${ACCESSOR_CONTENT}" "__HIP_PLATFORM_AMD__" ALREADY_PATCHED)
        
        if(ALREADY_PATCHED EQUAL -1)
            # Patch: Add !defined(__HIP_PLATFORM_AMD__) check to skip assume_aligned on ROCm
            string(REPLACE 
                "#if defined(__cpp_lib_assume_aligned)"
                "#if defined(__cpp_lib_assume_aligned) && !defined(__HIP_PLATFORM_AMD__)"
                ACCESSOR_CONTENT "${ACCESSOR_CONTENT}")
            file(WRITE "${ALIGNED_ACCESSOR_FILE}" "${ACCESSOR_CONTENT}")
            message(STATUS "✅ Patched RAFT's aligned_accessor.hpp to skip std::assume_aligned on ROCm")
        else()
            message(STATUS "✅ RAFT's aligned_accessor.hpp already patched")
        endif()
    else()
        message(WARNING "Could not find aligned_accessor.hpp to patch (looked at ${ALIGNED_ACCESSOR_FILE})")
    endif()
    
    # CRITICAL FIX: Patch RAFT's cuda_runtime.h for correct HIP device attribute names
    set(RAFT_CUDA_RUNTIME_H "${_RAFT_INCLUDE_ROOT}/raft/cuda_runtime.h")
    if(_RAFT_INCLUDE_ROOT AND EXISTS "${RAFT_CUDA_RUNTIME_H}")
        message(STATUS "🔧 Patching RAFT's cuda_runtime.h for HIP device attribute compatibility...")
        file(READ "${RAFT_CUDA_RUNTIME_H}" RAFT_CUDA_RUNTIME_CONTENT)
        
        # Fix: hipDevAttrMemoryPoolSupportedHandleTypes -> hipDeviceAttributeMemoryPoolSupportedHandleTypes
        string(REPLACE 
            "#define cudaDevAttrMemoryPoolSupportedHandleTypes hipDevAttrMemoryPoolSupportedHandleTypes"
            "#define cudaDevAttrMemoryPoolSupportedHandleTypes hipDeviceAttributeMemoryPoolSupportedHandleTypes"
            RAFT_CUDA_RUNTIME_CONTENT "${RAFT_CUDA_RUNTIME_CONTENT}")
        
        file(WRITE "${RAFT_CUDA_RUNTIME_H}" "${RAFT_CUDA_RUNTIME_CONTENT}")
        message(STATUS "✅ Patched RAFT's cuda_runtime.h - fixed hipDeviceAttributeMemoryPoolSupportedHandleTypes")
    else()
        message(WARNING "⚠️ RAFT's cuda_runtime.h not found at ${RAFT_CUDA_RUNTIME_H} - cannot patch!")
    endif()
    
    # CRITICAL FIX: Patch RAFT's cudart_utils.hpp to add missing 'inline' on
    # the full specialization of convert_to_device_type<half, uint16_t>.
    # Without 'inline', -fgpu-rdc linking produces duplicate symbols when
    # this header is included from multiple translation units.
    set(RAFT_CUDART_UTILS_H "${_RAFT_INCLUDE_ROOT}/raft/util/cudart_utils.hpp")
    if(_RAFT_INCLUDE_ROOT AND EXISTS "${RAFT_CUDART_UTILS_H}")
        file(READ "${RAFT_CUDART_UTILS_H}" CUDART_UTILS_CONTENT)
        
        string(FIND "${CUDART_UTILS_CONTENT}" "inline __device__ half convert_to_device_type" ALREADY_PATCHED)
        if(ALREADY_PATCHED EQUAL -1)
            string(REPLACE
                "__device__ half convert_to_device_type<half, uint16_t>"
                "inline __device__ half convert_to_device_type<half, uint16_t>"
                CUDART_UTILS_CONTENT "${CUDART_UTILS_CONTENT}")
            file(WRITE "${RAFT_CUDART_UTILS_H}" "${CUDART_UTILS_CONTENT}")
            message(STATUS "✅ Patched RAFT's cudart_utils.hpp - added inline to convert_to_device_type specialization")
        else()
            message(STATUS "✅ RAFT's cudart_utils.hpp already patched")
        endif()
    else()
        message(WARNING "⚠️ RAFT's cudart_utils.hpp not found at ${RAFT_CUDART_UTILS_H} - cannot patch!")
    endif()
    
else()
    # Original CUDA dependencies
    rapids_cpm_init()
    rapids_cmake_install_lib_dir(lib_dir)
    
    option(FETCH_RAPIDS "Fetch RAPIDS dependencies" ON)
    
    if (FETCH_RAPIDS)
      include(cmake/thirdparty/get_cccl.cmake)
      include(cmake/thirdparty/get_rmm.cmake)
      include(cmake/thirdparty/get_raft.cmake)
    else()
      find_package(CCCL REQUIRED)
      find_package(RMM REQUIRED)
      find_package(RAFT REQUIRED)
    endif()
    
    # Papilo for presolve - use local patched version with fmt 10.x compatibility
    set(PAPILO_PATCHED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../papilo_patched")
    if(EXISTS "${PAPILO_PATCHED_DIR}")
        message(STATUS "Using local patched papilo from ${PAPILO_PATCHED_DIR}")
        FetchContent_Declare(
          papilo
          SOURCE_DIR "${PAPILO_PATCHED_DIR}"
          EXCLUDE_FROM_ALL
          SYSTEM
        )
    else()
        message(STATUS "Local patched papilo not found, fetching from GitHub")
        FetchContent_Declare(
          papilo
          GIT_REPOSITORY "https://github.com/scipopt/papilo.git"
          GIT_TAG "741a2b9c8155b249d6df574d758b4d97d4417520"
          GIT_PROGRESS TRUE
          EXCLUDE_FROM_ALL
          SYSTEM
        )
    endif()
    
    find_package(TBB REQUIRED)
    set(BUILD_TESTING OFF CACHE BOOL "Disable test build for papilo")
    set(PAPILO_NO_BINARIES ON)
    option(LUSOL "Disable LUSOL" OFF)
    
    FetchContent_MakeAvailable(papilo)
    
    # Fetch spdlog (via rapids_logger)
    include(${rapids-cmake-dir}/cpm/rapids_logger.cmake)
    rapids_cpm_rapids_logger(BUILD_EXPORT_SET cuopt-exports INSTALL_EXPORT_SET cuopt-exports)
    create_logger_macros(CUOPT "cuopt::default_logger()" include/cuopt)
    
    # Note: papilo fmt headers are already patched in the local papilo_patched directory
    message(STATUS "✅ Using local patched papilo with fmt 10.x compatibility")
    
    # CUDSS is NVIDIA-specific and has no ROCm equivalent
    find_package(CUDSS REQUIRED)
endif()

if(BUILD_TESTS)
  if(USE_ROCM)
    # Fetch GTest manually for ROCm
    include(FetchContent)
    FetchContent_Declare(
      googletest
      GIT_REPOSITORY https://github.com/google/googletest.git
      GIT_TAG v1.14.0
    )
    FetchContent_MakeAvailable(googletest)
  else()
    include(cmake/thirdparty/get_gtest.cmake)
  endif()
endif()

set(CUOPT_SRC_FILES )
add_subdirectory(src)

# For ROCm: Mark all .cu files as HIP language
if(USE_ROCM)
    foreach(src_file ${CUOPT_SRC_FILES})
        if(src_file MATCHES "\\.cu$")
            set_source_files_properties(${src_file} PROPERTIES LANGUAGE HIP)
        endif()
    endforeach()
    message(STATUS "Marked ${CUOPT_SRC_FILES} .cu files as HIP sources")
endif()

if (HOST_LINEINFO)
  set_source_files_properties(${CUOPT_SRC_FILES} DIRECTORY ${CMAKE_SOURCE_DIR} PROPERTIES COMPILE_OPTIONS "-g1")
endif()

# Always name the library "cuopt" regardless of platform (CUDA or ROCm).
# The C++ layer handles platform differences internally; Python always does
# "import libcuopt".
add_library(cuopt SHARED ${CUOPT_SRC_FILES})
set(LIB_TARGET cuopt)
add_library(cuopt::cuopt ALIAS cuopt)

set_target_properties(${LIB_TARGET}
  PROPERTIES BUILD_RPATH "\$ORIGIN"
  INSTALL_RPATH "\$ORIGIN"

  # set target compile options
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  INTERFACE_POSITION_INDEPENDENT_CODE ON
  CXX_SCAN_FOR_MODULES OFF
)

if(USE_ROCM)
    set_target_properties(${LIB_TARGET} PROPERTIES
        HIP_STANDARD 20
        HIP_STANDARD_REQUIRED ON
    )
else()
    set_target_properties(${LIB_TARGET} PROPERTIES
        CUDA_STANDARD 20
        CUDA_STANDARD_REQUIRED ON
    )
endif()

target_compile_definitions(${LIB_TARGET} PUBLIC "CUOPT_LOG_ACTIVE_LEVEL=RAPIDS_LOGGER_LOG_LEVEL_${LIBCUOPT_LOGGING_LEVEL}")

if(USE_ROCM)
    target_compile_options(${LIB_TARGET}
      PRIVATE 
      "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
      "$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>"
    )
    # Note: __cpp_lib_assume_aligned is handled by force-including rocm_compat.hpp
    # which undefines it. Do NOT add any -D flags here as they override the #undef!
else()
    target_compile_options(${LIB_TARGET}
      PRIVATE 
      "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
      "$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>"
    )
endif()

if(WRITE_FATBIN AND NOT USE_ROCM)
  file(WRITE "${CUOPT_BINARY_DIR}/fatbin.ld"
    [=[
  SECTIONS
  {
    .nvFatBinSegment : { *(.nvFatBinSegment) }
    .nv_fatbin : { *(.nv_fatbin) }
  }
  ]=])
  target_link_options(${LIB_TARGET} PRIVATE "${CUOPT_BINARY_DIR}/fatbin.ld")
endif()

# ##################################################################################################
# - include paths ---------------------------------------------------------------------------------

if(USE_ROCM)
    message(STATUS "ROCm include directories: ${ROCM_PATH}/include")
    target_include_directories(${LIB_TARGET} SYSTEM PRIVATE "${papilo_SOURCE_DIR}/src" "${papilo_BINARY_DIR}")
else()
    message(STATUS "target include directories CUDSS_INCLUDES = ${CUDSS_INCLUDE}")
    target_include_directories(${LIB_TARGET} SYSTEM PRIVATE "${papilo_SOURCE_DIR}/src" "${papilo_BINARY_DIR}")
endif()

target_include_directories(${LIB_TARGET}
  PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../thirdparty"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
  PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/include>"
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/libmps_parser/include>"
  INTERFACE
  "$<INSTALL_INTERFACE:include>"
)

if(USE_ROCM)
    # IMPORTANT: spdlog include must come FIRST (BEFORE) to ensure bundled fmt is found
    # before any system/conda fmt that might be in other include paths
    target_include_directories(${LIB_TARGET} BEFORE PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}/_deps/spdlog-src/include  # spdlog + bundled fmt headers (must be first!)
    )
    target_include_directories(${LIB_TARGET} PRIVATE
        ${ROCM_PATH}/include
        ${hip_INCLUDE_DIRS}
        /opt/rocm/include  # Explicit ROCm include for hipsparse
    )
else()
    # CUDSS includes for CUDA builds only
    target_include_directories(${LIB_TARGET} PRIVATE "${CUDSS_INCLUDE}")
    target_include_directories(${LIB_TARGET} INTERFACE ${CUDSS_INCLUDE})
endif()

# ##################################################################################################
# - link libraries --------------------------------------------------------------------------------

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/libmps_parser)
set(CMAKE_LIBRARY_PATH ${CMAKE_CURRENT_BINARY_DIR}/libmps_parser/)

if(USE_ROCM)
    set(CUOPT_PRIVATE_LIBS
      TBB::tbb
      OpenMP::OpenMP_CXX
      hiprand
      hipsolver
    )
    
    message(STATUS "ROCm build: CUDSS disabled (NVIDIA-only library)")
    
else()
    # CUDA libraries
    set(CUOPT_PRIVATE_CUDA_LIBS
      CUDA::curand
      CUDA::cusolver
      TBB::tbb
      OpenMP::OpenMP_CXX
    )
    
    list(PREPEND CUOPT_PRIVATE_CUDA_LIBS CUDA::cublasLt)
    
    # CUDSS configuration for CUDA builds only
    get_filename_component(CUDSS_MT_LIB_FILE_NAME "${CUDSS_MT_LIB_FILE}" NAME)
    target_compile_definitions(${LIB_TARGET} PRIVATE 
        CUDSS_MT_LIB_FILE_NAME="${CUDSS_MT_LIB_FILE_NAME}"
        USE_CUDSS=1
    )
    
    message(STATUS "CUDA build: CUDSS enabled")
endif()

execute_process(
  COMMAND git rev-parse --short HEAD
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  OUTPUT_VARIABLE GIT_COMMIT_HASH
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
message("-- Building with GIT_COMMIT_HASH = '${GIT_COMMIT_HASH}'")

# Generate build_info.hpp from template
configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/src/utilities/build_info.hpp.in
  ${CMAKE_CURRENT_BINARY_DIR}/include/utilities/build_info.hpp
  @ONLY
)

# Add the generated include directory
target_include_directories(${LIB_TARGET} PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/include)

if(USE_ROCM)
    list(JOIN CMAKE_HIP_ARCHITECTURES "," JOINED_HIP_ARCHITECTURES)
    target_compile_definitions(${LIB_TARGET} PUBLIC
      CUOPT_HIP_ARCHITECTURES="${JOINED_HIP_ARCHITECTURES}"
      CUOPT_CPU_ARCHITECTURE="${CMAKE_SYSTEM_PROCESSOR}"
      # Force spdlog to use bundled fmt header-only mode
      FMT_HEADER_ONLY
      # Disable fmt consteval - HIP/Clang has issues with consteval in FMT_STRING macro
      # Setting FMT_CONSTEVAL to empty prevents compile-time format checking
      "FMT_CONSTEVAL="
      )
      
    target_link_libraries(${LIB_TARGET}
      PUBLIC
      hipblas
      hipsparse
      hip::host
      cuopt::mps_parser
      raft::raft
      rmm::rmm
      rapids_logger::rapids_logger_logger
      PRIVATE
      ${CUOPT_PRIVATE_LIBS}
      # The _impl targets use INTERFACE_SOURCES to compile logger.cpp into this library.
      # Without them, rmm::logger and rapids_logger::logger symbols are never defined.
      rmm::rmm_logger_impl
      rapids_logger::rapids_logger_logger_impl
    )
    
    # Link spdlog header-only to avoid compiled library/header mismatch with bundled fmt
    if(TARGET spdlog::spdlog_header_only)
        target_link_libraries(${LIB_TARGET} PRIVATE spdlog::spdlog_header_only)
    elseif(TARGET spdlog::spdlog)
        target_link_libraries(${LIB_TARGET} PRIVATE spdlog::spdlog)
    endif()
else()
    list(JOIN CMAKE_CUDA_ARCHITECTURES "," JOINED_CUDA_ARCHITECTURES)
    target_compile_definitions(${LIB_TARGET} PUBLIC
      CUOPT_CUDA_ARCHITECTURES="${JOINED_CUDA_ARCHITECTURES}"
      CUOPT_CPU_ARCHITECTURE="${CMAKE_SYSTEM_PROCESSOR}")
      
    target_link_libraries(${LIB_TARGET}
      PUBLIC
      CUDA::cublas
      CUDA::cusparse
      rmm::rmm
      rapids_logger::rapids_logger
      CCCL::CCCL
      raft::raft
      cuopt::mps_parser
      ${CUDSS_LIB_FILE}  # CUDSS for CUDA builds only
      PRIVATE
      ${CUOPT_PRIVATE_CUDA_LIBS}
    )
endif()

# ##################################################################################################
# - generate tests --------------------------------------------------------------------------------
if(BUILD_TESTS)
  # Re-enable BUILD_TESTING — it was set to OFF earlier to suppress papilo's
  # own test suite, but include(CTest) checks this variable and will NOT call
  # enable_testing() when it is OFF, leaving the root CTestTestfile.cmake
  # ungenerated and causing "No tests were found!!!" from ctest.
  set(BUILD_TESTING ON CACHE BOOL "Enable CTest" FORCE)
  include(CTest)
  add_subdirectory(tests)
endif(BUILD_TESTS)

# ##################################################################################################
# - install targets -------------------------------------------------------------------------------

# allows for CPack component builds and install location
set(CPACK_DEB_COMPONENT_INSTALL ON)
set(CPACK_COMPONENTS_ALL runtime dev)
set(CPACK_PACKAGING_INSTALL_PREFIX "/usr/local")

#If using cpack to create a deb package
if(CPACK_GENERATOR STREQUAL "DEB")
  set(_BIN_DEST "bin")
  set(_LIB_DEST "lib")
  set(_INCLUDE_DEST "lib/cuopt")
#If building locally use the Default install paths
else()
  if(USE_ROCM)
    rapids_cmake_install_lib_dir(lib_dir)
  else()
    set(lib_dir "${CMAKE_INSTALL_LIBDIR}")
  endif()
  set(_BIN_DEST "${CMAKE_INSTALL_BINDIR}")
  set(_LIB_DEST "${lib_dir}")
  set(_INCLUDE_DEST include/cuopt/)
endif()

# adds the .so files to the runtime deb package
install(TARGETS ${LIB_TARGET} mps_parser
  DESTINATION ${_LIB_DEST}
  COMPONENT runtime
)

if(NOT USE_ROCM)
    install(TARGETS ${LIB_TARGET} mps_parser
      EXPORT cuopt-exports
    )
endif()

# adds the .so files to the development deb package
install(TARGETS ${LIB_TARGET} mps_parser
  DESTINATION ${_LIB_DEST}
  COMPONENT dev
)

# adds the header files to the development deb package
install(DIRECTORY include/cuopt/
  DESTINATION ${_INCLUDE_DEST}
  COMPONENT dev
)

# adds the version header file to the development deb package
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/include/cuopt/version_config.hpp
  DESTINATION ${_INCLUDE_DEST}
  COMPONENT dev
)

# ###############################################################################################
# - install export -------------------------------------------------------------------------------
if(NOT USE_ROCM)
    set(doc_string
      [=[
    Provide targets for cuOpt.
    
    cuOpt library is a collection of GPU accelerated combinatorial optimization algorithms.
    
    ]=])
    
    rapids_export(INSTALL cuopt
      EXPORT_SET cuopt-exports
      GLOBAL_TARGETS cuopt
      NAMESPACE cuopt::
      DOCUMENTATION doc_string
    )
    
    # ###############################################################################################
    # - build export -------------------------------------------------------------------------------
    rapids_export(BUILD cuopt
      EXPORT_SET cuopt-exports
      GLOBAL_TARGETS cuopt
      NAMESPACE cuopt::
      DOCUMENTATION doc_string
    )
endif()

# ##################################################################################################
# - make documentation ----------------------------------------------------------------------------
find_package(Doxygen)

if(Doxygen_FOUND)
  add_custom_command(OUTPUT CUOPT_DOXYGEN
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/doxygen
    COMMAND doxygen Doxyfile
    VERBATIM)

  add_custom_target(docs_cuopt DEPENDS CUOPT_DOXYGEN)
endif()

if(NOT BUILD_LP_ONLY)
    set(CLI_TARGET cuopt_cli)
    
    add_executable(${CLI_TARGET} cuopt_cli.cpp)
    
    set_target_properties(${CLI_TARGET}
      PROPERTIES
      CXX_STANDARD 20
      CXX_STANDARD_REQUIRED ON
      CXX_SCAN_FOR_MODULES OFF
    )
    
    if(USE_ROCM)
        target_compile_options(${CLI_TARGET}
          PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
          "$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>"
        )
    else()
        target_compile_options(${CLI_TARGET}
          PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
          "$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>"
        )
    endif()
    
    target_include_directories(${CLI_TARGET}
      PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src"
      PUBLIC
      "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
      "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/include>"
      "$<INSTALL_INTERFACE:include>"
    )
    
    if(USE_ROCM)
        target_link_libraries(${CLI_TARGET}
          PUBLIC
          ${LIB_TARGET}
          OpenMP::OpenMP_CXX
          TBB::tbb
          PRIVATE
        )
        target_include_directories(${CLI_TARGET} PRIVATE 
          ${ROCM_PATH}/include
          ${CMAKE_CURRENT_BINARY_DIR}/_deps/spdlog-src/include
          ${CMAKE_CURRENT_BINARY_DIR}/_deps/libhipcxx-src/include
        )
    else()
        # CUDSS for CUDA builds only
        target_include_directories(${CLI_TARGET} PRIVATE ${CUDSS_INCLUDE})
        target_link_libraries(${CLI_TARGET}
          PUBLIC
          ${LIB_TARGET}
          OpenMP::OpenMP_CXX
          ${CUDSS_LIBRARIES}
          TBB::tbb
          PRIVATE
        )
    endif()
    
    # Use RUNPATH when building locally
    if(NOT DEFINED INSTALL_TARGET OR "${INSTALL_TARGET}" STREQUAL "")
      target_link_options(${CLI_TARGET} PRIVATE -Wl,--enable-new-dtags)
    endif()
    set_property(TARGET ${CLI_TARGET} PROPERTY INSTALL_RPATH "$ORIGIN/../${lib_dir}")
    
    # adds the CLI executable to the runtime deb package
    install(TARGETS ${CLI_TARGET}
      COMPONENT runtime
      RUNTIME DESTINATION ${_BIN_DEST}
    )
endif()

# Benchmarks
option(BUILD_MIP_BENCHMARKS "Build MIP benchmarks" OFF)
if(BUILD_MIP_BENCHMARKS AND NOT BUILD_LP_ONLY)
  add_executable(solve_MIP ../benchmarks/linear_programming/cuopt/run_mip.cpp)

  set_target_properties(solve_MIP
    PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    CXX_SCAN_FOR_MODULES OFF
  )

  if(USE_ROCM)
      target_compile_options(solve_MIP
        PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>"
      )
  else()
      target_compile_options(solve_MIP
        PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>"
      )
  endif()
  
  target_link_libraries(solve_MIP
    PUBLIC
    ${LIB_TARGET}
    OpenMP::OpenMP_CXX
    PRIVATE
  )
  
  if(NOT DEFINED INSTALL_TARGET OR "${INSTALL_TARGET}" STREQUAL "")
    target_link_options(solve_MIP PRIVATE -Wl,--enable-new-dtags)
  endif()

  target_include_directories(solve_MIP
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
endif()

option(BUILD_LP_BENCHMARKS "Build LP benchmarks" OFF)
if(BUILD_LP_BENCHMARKS)
  add_executable(solve_LP ../benchmarks/linear_programming/cuopt/run_pdlp.cu)

  set_target_properties(solve_LP
    PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    CXX_SCAN_FOR_MODULES OFF
  )
  
  if(USE_ROCM)
      set_target_properties(solve_LP PROPERTIES
          HIP_STANDARD 20
          HIP_STANDARD_REQUIRED ON
      )
      target_compile_options(solve_LP
        PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>"
      )
  else()
      set_target_properties(solve_LP PROPERTIES
          CUDA_STANDARD 20
          CUDA_STANDARD_REQUIRED ON
      )
      target_compile_options(solve_LP
        PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>"
      )
  endif()
  
  target_link_libraries(solve_LP
    PUBLIC
    ${LIB_TARGET}
    OpenMP::OpenMP_CXX
    PRIVATE
  )
  
  if(NOT DEFINED INSTALL_TARGET OR "${INSTALL_TARGET}" STREQUAL "")
    target_link_options(solve_LP PRIVATE -Wl,--enable-new-dtags)
  endif()
endif()

# ##################################################################################################
# - CPack -------------------------------------------------------------------------------------
set(CPACK_GENERATOR "DEB")

# Runtime package metadata
execute_process(COMMAND dpkg --print-architecture OUTPUT_VARIABLE DEB_ARCH OUTPUT_STRIP_TRAILING_WHITESPACE)

# Unified package name: "cuopt" on both CUDA and ROCm platforms.
# The C++ layer handles platform-specific GPU APIs internally.
set(CPACK_DEBIAN_PACKAGE_NAME "cuOpt")
set(CPACK_PACKAGE_FILE_NAME "cuOpt_${PROJECT_VERSION}_${DEB_ARCH}")
set(CPACK_COMPONENT_RUNTIME_DESCRIPTION "cuOpt runtime components (binaries and shared libraries)")
set(CPACK_COMPONENT_RUNTIME_DISPLAY_NAME "cuOpt Runtime")
set(CPACK_DEBIAN_RUNTIME_PACKAGE_NAME "cuopt")
set(CPACK_DEBIAN_RUNTIME_PACKAGE_FILE_NAME "cuopt_${PROJECT_VERSION}_${DEB_ARCH}")
set(CPACK_COMPONENT_DEV_DESCRIPTION "cuOpt development files (headers, symlinks, etc.)")
set(CPACK_COMPONENT_DEV_DISPLAY_NAME "cuOpt Development")
set(CPACK_DEBIAN_DEV_PACKAGE_NAME "cuopt-dev")
set(CPACK_DEBIAN_DEV_PACKAGE_FILE_NAME "cuopt-dev_${PROJECT_VERSION}_${DEB_ARCH}")

set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "AMD/NVIDIA")
set(CPACK_COMPONENT_RUNTIME_GROUP "Runtime")
set(CPACK_COMPONENT_DEV_GROUP "Development")

# MUST BE THE LAST ITEM IN THE CMAKE FILE!!!
include(CPack)
