# SPDX-FileCopyrightText: Copyright (c) 2021-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set(CUOPT_MIN_VERSION_raft "${DEPENDENT_LIB_MAJOR_VERSION}.${DEPENDENT_LIB_MINOR_VERSION}.00")
set(CUOPT_BRANCH_VERSION_raft "${DEPENDENT_LIB_MAJOR_VERSION}.${DEPENDENT_LIB_MINOR_VERSION}")
set(RAFT_VERSION "0.1.0")
set(RAFT_FORK "ROCm-DS")
set(RAFT_PINNED_TAG "release/rocmds-26.03")

# hipRaft source location.  The open-source ROCm-DS/hipRaft repo now carries the
# release/rocmds-26.03 branch, so an anonymous HTTPS clone works.  This must
# match the RAFT version the amd-pylibraft / amd-libraft wheels (used by the
# Python build) are built from.
#
# The GitHub org can be overridden with RAPIDS_CMAKE_ROCM_DS_ORG (e.g. to point
# at a private fork); when GH_USERNAME / GH_TOKEN are also set, credentials are
# injected so an authenticated clone of such a fork still works.
if(DEFINED ENV{RAPIDS_CMAKE_ROCM_DS_ORG} AND NOT "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}" STREQUAL "")
    set(RAFT_GH_ORG "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}")
else()
    set(RAFT_GH_ORG "ROCm-DS")
endif()
if(DEFINED ENV{GH_USERNAME} AND DEFINED ENV{GH_TOKEN})
    set(RAFT_GIT_REPOSITORY "https://$ENV{GH_USERNAME}:$ENV{GH_TOKEN}@github.com/${RAFT_GH_ORG}/hipRaft.git")
    message(STATUS "Using authenticated HTTPS access to ${RAFT_GH_ORG}/hipRaft")
else()
    set(RAFT_GIT_REPOSITORY "https://github.com/${RAFT_GH_ORG}/hipRaft.git")
    message(STATUS "Using public ROCm-DS hipRaft from ${RAFT_GH_ORG}/hipRaft")
endif()

function(find_and_configure_raft)
    set(oneValueArgs VERSION FORK PINNED_TAG COMPILE_LIBRARY ENABLE_MNMG_DEPENDENCIES CLONE_ON_PIN)
    cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT CPM_raft_SOURCE AND PKG_CLONE_ON_PIN AND NOT PKG_PINNED_TAG STREQUAL "release/rocmds-26.03")
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
            GIT_REPOSITORY ${RAFT_GIT_REPOSITORY}
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
