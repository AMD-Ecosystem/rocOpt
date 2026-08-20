# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: ROCm port modifications (c) 2026
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

cmake_minimum_required(VERSION 3.26.4 FATAL_ERROR)

# Detect platform: CUDA or ROCm BEFORE project() call
set(USE_ROCM ON CACHE BOOL "Build with ROCm instead of CUDA")

if(USE_ROCM)
    message(STATUS "Python cuopt: Building for ROCm/HIP platform")

    # Set ROCM_PATH early
    if(NOT DEFINED ROCM_PATH)
        if(DEFINED ENV{ROCM_PATH})
            set(ROCM_PATH $ENV{ROCM_PATH} CACHE PATH "Path to ROCm installation")
        elseif(EXISTS "/opt/rocm")
            set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to ROCm installation")
        else()
            set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to ROCm installation")
        endif()
    endif()

    # Set HIP compiler BEFORE project()
    if(EXISTS "${ROCM_PATH}/bin/amdclang++")
        set(CMAKE_HIP_COMPILER "${ROCM_PATH}/bin/amdclang++" CACHE FILEPATH "HIP compiler")
        set(CMAKE_CXX_COMPILER "${ROCM_PATH}/bin/amdclang++" CACHE FILEPATH "CXX compiler")
        set(CMAKE_C_COMPILER "${ROCM_PATH}/bin/amdclang" CACHE FILEPATH "C compiler")
    elseif(EXISTS "${ROCM_PATH}/bin/hipcc")
        set(CMAKE_HIP_COMPILER "${ROCM_PATH}/bin/hipcc" CACHE FILEPATH "HIP compiler")
    else()
        message(FATAL_ERROR "Could not find amdclang++ or hipcc in ${ROCM_PATH}/bin/")
    endif()

    set(CMAKE_HIP_COMPILER_ROCM_ROOT "${ROCM_PATH}" CACHE PATH "ROCm root for HIP compiler")

    list(APPEND CMAKE_PREFIX_PATH
        ${ROCM_PATH}
        ${ROCM_PATH}/lib/cmake
        ${ROCM_PATH}/hip
        ${ROCM_PATH}/lib/cmake/hip
        ${ROCM_PATH}/lib/cmake/hip-lang
    )

    # ROCm-DS rapids-cmake: https://github.com/ROCm-DS/ROCmDS-CMake (release/rocmds-26.03)
    # This is the open-source ROCm-DS CMake module collection; an anonymous
    # HTTPS clone works and no credentials are required.
    include(FetchContent)

    # Allow a pre-cloned local copy to bypass the GitHub fetch entirely.
    # Set ROCMDS_CMAKE_LOCAL_PATH (a valid shell variable name, no dashes) to the
    # path of a local ROCmDS-CMake checkout.
    if(DEFINED ENV{ROCMDS_CMAKE_LOCAL_PATH} AND NOT "$ENV{ROCMDS_CMAKE_LOCAL_PATH}" STREQUAL "")
        set(ROCMDS_CMAKE_LOCAL_PATH "$ENV{ROCMDS_CMAKE_LOCAL_PATH}")
        if(EXISTS "${ROCMDS_CMAKE_LOCAL_PATH}" AND IS_DIRECTORY "${ROCMDS_CMAKE_LOCAL_PATH}")
            set(FETCHCONTENT_SOURCE_DIR_RAPIDS-CMAKE "${ROCMDS_CMAKE_LOCAL_PATH}" CACHE PATH "")
            message(STATUS "Using local ROCmDS-CMake: ${ROCMDS_CMAKE_LOCAL_PATH}")
        else()
            message(FATAL_ERROR
                "ROCMDS_CMAKE_LOCAL_PATH is set to '${ROCMDS_CMAKE_LOCAL_PATH}', "
                "but that path does not exist or is not a directory. "
                "Please set it to a valid local ROCmDS-CMake checkout.")
        endif()
    endif()

    # Default to the public ROCm-DS org.  The org can be overridden via
    # RAPIDS_CMAKE_ROCM_DS_ORG (e.g. to point at a private fork); when
    # GH_USERNAME / GH_TOKEN are also set, credentials are injected so an
    # authenticated clone of such a fork still works.
    if(DEFINED ENV{RAPIDS_CMAKE_ROCM_DS_ORG} AND NOT "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}" STREQUAL "")
        set(_rocmds_cmake_org "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}")
    else()
        set(_rocmds_cmake_org "ROCm-DS")
    endif()
    if(DEFINED ENV{GH_USERNAME} AND DEFINED ENV{GH_TOKEN})
        set(RAPIDS_CMAKE_REPO "https://$ENV{GH_USERNAME}:$ENV{GH_TOKEN}@github.com/${_rocmds_cmake_org}/ROCmDS-CMake.git")
        message(STATUS "Using authenticated HTTPS access to ${_rocmds_cmake_org}/ROCmDS-CMake")
    else()
        set(RAPIDS_CMAKE_REPO "https://github.com/${_rocmds_cmake_org}/ROCmDS-CMake.git")
        message(STATUS "Using public ROCm-DS rapids-cmake from ${_rocmds_cmake_org}/ROCmDS-CMake")
    endif()

    FetchContent_Declare(
      rapids-cmake
      GIT_REPOSITORY ${RAPIDS_CMAKE_REPO}
      GIT_TAG release/rocmds-26.03
    )
    FetchContent_MakeAvailable(rapids-cmake)

    include(${rapids-cmake_SOURCE_DIR}/RAPIDS.cmake)
    include(rapids-cmake)
    include(rapids-hip)

    # Initialize HIP architectures.
    # Ensure GPU_TARGETS matches CMAKE_HIP_ARCHITECTURES to avoid mismatch
    # when multiple GPUs of the same arch are detected (e.g., 8x gfx90a causes
    # GPU_TARGETS="gfx90a;gfx90a;...;gfx90a" while CMAKE_HIP_ARCHITECTURES="gfx90a").
    if(DEFINED CMAKE_HIP_ARCHITECTURES)
        list(REMOVE_DUPLICATES CMAKE_HIP_ARCHITECTURES)
        set(GPU_TARGETS "${CMAKE_HIP_ARCHITECTURES}" CACHE STRING "GPU targets" FORCE)
    endif()
    include(${rapids-cmake_SOURCE_DIR}/rapids-cmake/hip/init_architectures.cmake)
    rapids_hip_init_architectures(CUOPT)

    # Read version from VERSION file
    file(READ "${CMAKE_CURRENT_LIST_DIR}/../../VERSION" _rapids_version)
    string(STRIP "${_rapids_version}" RAPIDS_VERSION)

    project(
      cuopt-python
      VERSION "${RAPIDS_VERSION}"
      LANGUAGES C CXX HIP)

    find_package(hip REQUIRED)

    # Add ROCm include path globally so Cython-generated CXX files
    # can find hip/hip_runtime.h when compiled with the conda GCC compiler.
    include_directories(SYSTEM ${ROCM_PATH}/include)

    # Add conda env include path explicitly so hipMM (rmm/) and hipRaft (raft/)
    # headers from the pip-installed amd-hipmm and amd-pylibraft packages are
    # found with correct priority (before any C++ build _deps headers).
    if(DEFINED ENV{CONDA_PREFIX})
        include_directories(SYSTEM $ENV{CONDA_PREFIX}/include)
        message(STATUS "Added conda env include: $ENV{CONDA_PREFIX}/include")

        # libhipcxx headers (cuda/stream_ref, cuda/std/*, etc.) are installed
        # under rapids/libhipcxx/ by the amd-hipmm pip package.  The RMM
        # headers reference them via bare <cuda/stream_ref> includes.
        if(EXISTS "$ENV{CONDA_PREFIX}/include/rapids/libhipcxx")
            include_directories(SYSTEM $ENV{CONDA_PREFIX}/include/rapids/libhipcxx)
            message(STATUS "Added libhipcxx include: $ENV{CONDA_PREFIX}/include/rapids/libhipcxx")
        endif()
    endif()

    # The amd-libraft / amd-pylibraft wheels install their RAFT C++ headers
    # under <site-packages>/libraft/include (and /pylibraft/include), NOT under
    # $CONDA_PREFIX/include.  These wheel headers are the 26.03 hipRaft headers
    # that match the amd-pylibraft Cython bindings (which reference
    # raft/core/device_resources_snmg.hpp).  Locate and add them with priority
    # so the generated wrappers compile against the same RAFT version they were
    # generated from, instead of falling back to the older C++ raft-src.
    set(_raft_wheel_include "")
    find_program(_python_exe NAMES python python3)
    if(_python_exe)
        foreach(_pkg libraft pylibraft)
            execute_process(
                COMMAND ${_python_exe} -c
                    "import os,importlib.util as u;s=u.find_spec('${_pkg}');p=os.path.join(os.path.dirname(s.origin),'include') if s and s.origin else '';print(p if os.path.isdir(p) else '')"
                OUTPUT_VARIABLE _pkg_inc
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET)
            if(_pkg_inc AND IS_DIRECTORY "${_pkg_inc}")
                include_directories(SYSTEM ${_pkg_inc})
                message(STATUS "Added RAFT wheel include (${_pkg}): ${_pkg_inc}")
                if(EXISTS "${_pkg_inc}/raft/core/handle.hpp")
                    set(_raft_wheel_include "${_pkg_inc}")
                endif()
            endif()
        endforeach()
    endif()
    if(_raft_wheel_include STREQUAL "")
        message(WARNING
            "Could not locate libraft/pylibraft wheel include dir. The Cython "
            "wrappers may fall back to the C++ raft-src, which can be a "
            "different RAFT version than the installed amd-pylibraft wheel.")
    endif()

    # HIP headers require __HIP_PLATFORM_AMD__ to be defined.
    add_compile_definitions(__HIP_PLATFORM_AMD__)

    # Enable experimental memory resource support in libhipcxx.
    # This feature gate enables the cuda::mr namespace types (device_accessible,
    # host_accessible, resource_ref, async_resource_ref, async_resource_with)
    # that RMM/hipMM headers depend on. Without this, cuda::mr is not defined
    # in libhipcxx and RMM headers fail to compile.
    # The C++ build (cpp/CMakeLists.txt) also defines this.
    add_compile_definitions(LIBCUDACXX_ENABLE_EXPERIMENTAL_MEMORY_RESOURCE)

    # Cython-generated .cxx files include raft/rocprim headers containing GPU
    # device intrinsics (__popcll, atomicAdd, __builtin_amdgcn_wavefrontsize, etc.)
    # These are only available when compiling in HIP mode.
    # -xhip:               treat .cxx source as HIP (enables device builtins)
    # --offload-host-only: only emit host code (no GPU kernels needed for Python wrappers)
    # IMPORTANT: use add_compile_options, NOT CMAKE_CXX_FLAGS, so these flags
    # apply only to compilation and NOT to the linker (which would try to parse
    # .o files as HIP source code).
    add_compile_options(-xhip --offload-host-only)

    # Add include paths from the C++ build's fetched dependencies.
    # The C++ build (via ROCmDS-cmake's rapids_cpm_cccl -> hipccl.cmake ->
    # rapids_cpm_libhipcxx) fetches libhipcxx 2.7.0 from
    # https://github.com/ROCm/libhipcxx at tag release/rocmds-25.10.
    # It also fetches hipmm (RMM), hipRaft, cuCollections, fmt, spdlog, etc.
    #
    # When the pip-installed amd-hipmm / amd-pylibraft packages provide
    # headers in the conda env, we prefer those over the C++ build _deps
    # copies.  If the installed headers are absent we fall back to _deps.
    set(CPP_BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/../../cpp/build")

    # Detect whether hipMM / hipRaft headers are already available
    set(_has_hipmm_headers FALSE)
    set(_has_hipraft_headers FALSE)
    if(DEFINED ENV{CONDA_PREFIX})
        if(EXISTS "$ENV{CONDA_PREFIX}/include/rmm/cuda_stream_view.hpp")
            set(_has_hipmm_headers TRUE)
        endif()
        if(EXISTS "$ENV{CONDA_PREFIX}/include/raft/core/handle.hpp")
            set(_has_hipraft_headers TRUE)
        endif()
    endif()
    # If the RAFT headers came from the installed wheel (above), prefer those
    # over the C++ build's raft-src so versions stay consistent with the
    # amd-pylibraft Cython bindings.
    if(NOT _raft_wheel_include STREQUAL "")
        set(_has_hipraft_headers TRUE)
    endif()

    if(EXISTS "${CPP_BUILD_DIR}/_deps")
        file(GLOB _dep_include_dirs "${CPP_BUILD_DIR}/_deps/*/include")
        foreach(_dir ${_dep_include_dirs})
            string(FIND "${_dir}" "/rmm-" _is_rmm)
            string(FIND "${_dir}" "/raft-" _is_raft)
            if(_is_rmm GREATER -1 AND _has_hipmm_headers)
                message(STATUS "SKIPPING C++ dep include (using hipMM instead): ${_dir}")
            elseif(_is_raft GREATER -1 AND _has_hipraft_headers)
                message(STATUS "SKIPPING C++ dep include (using hipRaft instead): ${_dir}")
            else()
                message(STATUS "Adding C++ dep include: ${_dir}")
                include_directories(SYSTEM ${_dir})
            endif()
        endforeach()
    else()
        message(WARNING "C++ build _deps directory not found at ${CPP_BUILD_DIR}/_deps - some headers may be missing")
    endif()

else()
    message(STATUS "Python cuopt: Building for NVIDIA CUDA platform")

    include(../../cmake/rapids_config.cmake)
    include(rapids-cuda)
    rapids_cuda_init_architectures(CUOPT)

    project(
      cuopt-python
      VERSION "${RAPIDS_VERSION}"
      LANGUAGES C CXX CUDA)
endif()

find_package(cuopt "${RAPIDS_VERSION}" QUIET)
find_package(mps_parser "${RAPIDS_VERSION}" QUIET)

# For ROCm: cmake config files may not be exported, so create IMPORTED targets
# manually when find_package fails.
if(USE_ROCM)
    if(NOT TARGET cuopt::cuopt)
        message(STATUS "cuopt::cuopt not found via find_package, creating IMPORTED target")
        find_library(CUOPT_LIBRARY NAMES cuopt
            HINTS ${CMAKE_LIBRARY_PATH}
            PATH_SUFFIXES lib lib64
        )
        if(NOT CUOPT_LIBRARY)
            message(FATAL_ERROR "Could not find libcuopt.so. Build libcuopt first: ./build.sh libcuopt")
        endif()
        message(STATUS "Found libcuopt: ${CUOPT_LIBRARY}")
        add_library(cuopt::cuopt SHARED IMPORTED)
        set_target_properties(cuopt::cuopt PROPERTIES
            IMPORTED_LOCATION "${CUOPT_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../cpp/include;${CMAKE_CURRENT_LIST_DIR}/../../cpp/build/include"
        )
    endif()

    if(NOT TARGET cuopt::mps_parser)
        message(STATUS "cuopt::mps_parser not found via find_package, creating IMPORTED target")
        find_library(MPS_PARSER_LIBRARY NAMES mps_parser
            HINTS ${CMAKE_LIBRARY_PATH}
            PATH_SUFFIXES lib lib64
        )
        if(NOT MPS_PARSER_LIBRARY)
            message(FATAL_ERROR "Could not find libmps_parser.so. Build libmps_parser first: ./build.sh libmps_parser")
        endif()
        message(STATUS "Found libmps_parser: ${MPS_PARSER_LIBRARY}")
        add_library(cuopt::mps_parser SHARED IMPORTED)
        set_target_properties(cuopt::mps_parser PROPERTIES
            IMPORTED_LOCATION "${MPS_PARSER_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../cpp/libmps_parser/include"
        )
    endif()
endif()

include(rapids-cython-core)
rapids_cython_init()

add_subdirectory(cuopt)
add_subdirectory(cuopt/linear_programming/internals/)
