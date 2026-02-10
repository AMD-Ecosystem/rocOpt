# SPDX-FileCopyrightText: Copyright (c) 2021-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set(CUOPT_MIN_VERSION_raft "${DEPENDENT_LIB_MAJOR_VERSION}.${DEPENDENT_LIB_MINOR_VERSION}.00")
set(CUOPT_BRANCH_VERSION_raft "${DEPENDENT_LIB_MAJOR_VERSION}.${DEPENDENT_LIB_MINOR_VERSION}")
set(RAFT_VERSION "0.1.0")
set(RAFT_FORK "ROCm-DS")
set(RAFT_PINNED_TAG "release/rocmds-25.10")

function(find_and_configure_raft)
    set(oneValueArgs VERSION FORK PINNED_TAG COMPILE_LIBRARY ENABLE_MNMG_DEPENDENCIES CLONE_ON_PIN)
    cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT CPM_raft_SOURCE AND PKG_CLONE_ON_PIN AND NOT PKG_PINNED_TAG STREQUAL "release/rocmds-25.10")
        message(STATUS "RAFT pinned tag found: ${PKG_PINNED_TAG}. Cloning raft locally.")
        set(CPM_DOWNLOAD_raft ON)
    endif()

    set(RAFT_COMPONENTS "")
    if(PKG_COMPILE_LIBRARY)
        string(APPEND RAFT_COMPONENTS " compiled")
    endif()

    if(PKG_ENABLE_MNMG_DEPENDENCIES)
        string(APPEND RAFT_COMPONENTS " distributed")
    endif()

    rapids_cpm_find(raft ${PKG_VERSION}
            # GLOBAL_TARGETS      raft::raft        # Disabled - CPM 0.40.0 doesn't support this
            # BUILD_EXPORT_SET    cuopt-exports     # Disabled - CPM 0.40.0 doesn't support this
            # INSTALL_EXPORT_SET  cuopt-exports     # Disabled - CPM 0.40.0 doesn't support this
            COMPONENTS          ${RAFT_COMPONENTS}
            CPM_ARGS
            GIT_REPOSITORY https://github.com/ROCm-DS/hipRaft.git
            GIT_TAG        ${PKG_PINNED_TAG}
            SOURCE_SUBDIR  cpp
            OPTIONS
                "BUILD_TESTS OFF"
                "BUILD_PRIMS_BENCH OFF"
                "BUILD_ANN_BENCH OFF"
                "RAFT_COMPILE_LIBRARY ${PKG_COMPILE_LIBRARY}"
                "NVTX_ENABLED OFF"
                "CMAKE_CXX_FLAGS=-D__cpp_lib_assume_aligned=0"
                "CMAKE_HIP_FLAGS=-D__cpp_lib_assume_aligned=0"
            )
endfunction()

# Don't call the function here - let CMakeLists.txt call it in the right order
