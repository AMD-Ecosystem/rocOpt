# SPDX-FileCopyrightText: Copyright (c) 2021-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

function(find_and_configure_rmm)
    # For ROCm, directly use CPMAddPackage to fetch hipmm
    # rapids_cpm_find doesn't work with custom repos in ROCm-DS rapids-cmake
    
    # hipMM source location.  The open-source ROCm-DS/hipMM repo now carries the
    # release/rocmds-26.03 branch, so an anonymous HTTPS clone works.  The 26.03
    # branch consumes the rapids_logger via create_logger_macros() and links the
    # real rapids_logger::rapids_logger library, matching the 26.03 logger pinned
    # in cpp/CMakeLists.txt (the 25.10 branch used the now-defunct
    # rapids_make_logger() path).
    #
    # The GitHub org can be overridden with RAPIDS_CMAKE_ROCM_DS_ORG (e.g. to
    # point at a private fork); credentials for such a fork are taken from the
    # global git credential rewrite injected by the Dockerfile, mirroring how
    # hipRaft is fetched in get_raft.cmake.
    if(DEFINED ENV{RAPIDS_CMAKE_ROCM_DS_ORG} AND NOT "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}" STREQUAL "")
        set(RMM_GH_ORG "$ENV{RAPIDS_CMAKE_ROCM_DS_ORG}")
    else()
        set(RMM_GH_ORG "ROCm-DS")
    endif()

    message(STATUS "Fetching hipMM from ${RMM_GH_ORG}...")

    # CPM is already included by rapids-cmake, just use CPMAddPackage
    # The 26.03 hipMM repo has no top-level CMakeLists.txt — the rmm project
    # lives under cpp/ — so SOURCE_SUBDIR is required for CPM to configure it and
    # create the rmm / rmm::rmm targets (the 25.10 layout had a root CMakeLists).
    CPMAddPackage(
        NAME rmm
        GIT_REPOSITORY https://github.com/${RMM_GH_ORG}/hipMM.git
        GIT_TAG release/rocmds-26.03
        SOURCE_SUBDIR cpp
        OPTIONS
            "BUILD_TESTS OFF"
            "BUILD_BENCHMARKS OFF"
    )
    
    message(STATUS "RMM package added, checking for targets...")
    
    # Debug: Print all available targets that contain 'rmm'
    get_property(_all_targets DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} PROPERTY BUILDSYSTEM_TARGETS)
    foreach(_target ${_all_targets})
        string(FIND "${_target}" "rmm" _pos)
        if(NOT ${_pos} EQUAL -1)
            message(STATUS "  Found target: ${_target}")
        endif()
    endforeach()
    
    # Create rmm::rmm alias - try different possible target names
    if(TARGET rmm::rmm)
        message(STATUS "✅ rmm::rmm target already exists")
    elseif(TARGET rmm)
        add_library(rmm::rmm ALIAS rmm)
        message(STATUS "✅ Created rmm::rmm alias from rmm target")
    elseif(TARGET hipmm)
        add_library(rmm::rmm ALIAS hipmm)
        message(STATUS "✅ Created rmm::rmm alias from hipmm target")
    else()
        message(WARNING "⚠️ Could not find rmm or hipmm target to create alias!")
        message(WARNING "   Available targets: ${_all_targets}")
    endif()
endfunction()

# Don't call the function here - let CMakeLists.txt call it in the right order
