# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

ConfigureTest(LP_UNIT_TEST
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/optimization_problem_test.cu
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/solver_settings_test.cu
)# ##################################################################################################
# - Linear programming PDLP tests ----------------------------------------------------------------------
ConfigureTest(PDLP_TEST
    ${CMAKE_CURRENT_SOURCE_DIR}/pdlp_test.cu
)

# ##################################################################################################
# - C API Tests----------------------------------------------------------------------
# The C API tests require a separate library to be linked against. So we don't use the ConfigureTest macro.

if (NOT SKIP_C_PYTHON_ADAPTERS)
    add_library(c_api_tester STATIC "${CMAKE_CURRENT_SOURCE_DIR}/c_api_tests/c_api_test.c")
    target_include_directories(c_api_tester
        PRIVATE
        "${CMAKE_BINARY_DIR}/_deps/libhipcxx-src/include"  # Must be first for cuda::mr
        "${CMAKE_BINARY_DIR}/include"  # Generated headers (logger_macros.hpp)
        "${CUOPT_TEST_DIR}/../include"
        "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include"
        "${CMAKE_BINARY_DIR}/_deps/raft-build/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-src/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-build/include"
        "${CMAKE_BINARY_DIR}/_deps/spdlog-src/include"
        PUBLIC
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/include>"
    )

    target_compile_definitions(c_api_tester
        PRIVATE
        LIBCUDACXX_ENABLE_EXPERIMENTAL_MEMORY_RESOURCE
    )
    target_include_directories(c_api_tester
        PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/c_api_tests"
    )

    add_executable(C_API_TEST "${CMAKE_CURRENT_SOURCE_DIR}/c_api_tests/c_api_tests.cpp")

    target_include_directories(C_API_TEST
        PRIVATE
        "${CMAKE_BINARY_DIR}/_deps/libhipcxx-src/include"  # Must be first for cuda::mr
        "${CMAKE_BINARY_DIR}/include"  # Generated headers (logger_macros.hpp)
        "${CUOPT_TEST_DIR}/../src"
        "${CUOPT_TEST_DIR}/../include"
        "${CUOPT_TEST_DIR}/../libmps_parser/src"
        "${CUOPT_TEST_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/c_api_tests"
        "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include"
        "${CMAKE_BINARY_DIR}/_deps/raft-build/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-src/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-build/include"
        "${CMAKE_BINARY_DIR}/_deps/spdlog-src/include"
    )

    target_compile_definitions(C_API_TEST
        PRIVATE
        LIBCUDACXX_ENABLE_EXPERIMENTAL_MEMORY_RESOURCE
    )

    if(USE_ROCM)
        target_link_directories(C_API_TEST PRIVATE ${ROCM_PATH}/lib)
    endif()

    target_link_libraries(C_API_TEST
        PRIVATE
        mps_parser
        ${LIB_TARGET}
        cuopttestutils
        c_api_tester
        GTest::gmock
        GTest::gmock_main
        GTest::gtest
        GTest::gtest_main
    )
    if(USE_ROCM)
        target_link_libraries(C_API_TEST PRIVATE ${CUOPT_PRIVATE_LIBS})
    else()
        target_link_libraries(C_API_TEST PRIVATE ${CUOPT_PRIVATE_CUDA_LIBS})
    endif()

    add_test(NAME C_API_TEST COMMAND C_API_TEST)

    install(
        TARGETS C_API_TEST
        COMPONENT testing
        DESTINATION bin/gtests/libcuopt
        EXCLUDE_FROM_ALL
    )
endif()
