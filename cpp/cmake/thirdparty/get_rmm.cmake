# SPDX-FileCopyrightText: Copyright (c) 2021-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

function(find_and_configure_rmm)
    # For ROCm, directly use CPMAddPackage to fetch hipmm
    # rapids_cpm_find doesn't work with custom repos in AMD-AIOSS rapids-cmake
    
    message(STATUS "Fetching hipmm from ROCm-DS...")
    
    # CPM is already included by rapids-cmake, just use CPMAddPackage
    CPMAddPackage(
        NAME rmm
        GIT_REPOSITORY https://github.com/ROCm-DS/hipmm.git
        GIT_TAG release/rocmds-25.10
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
