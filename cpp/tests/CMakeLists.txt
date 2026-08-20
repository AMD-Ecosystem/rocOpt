# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2021-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

if(BUILD_TESTS)
  add_library(cuopttestutils STATIC
      routing/utilities/check_constraints.cu
  )

  # For ROCm: Mark test .cu files as HIP
  if(USE_ROCM)
    set_source_files_properties(routing/utilities/check_constraints.cu PROPERTIES LANGUAGE HIP)
  endif()

  target_compile_options(cuopttestutils
      PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
      "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>>"
      "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>>"
  )

  target_include_directories(cuopttestutils
      PRIVATE
      "${CMAKE_BINARY_DIR}/_deps/libhipcxx-src/include"  # Must be first for cuda::mr
      "${CMAKE_BINARY_DIR}/include"  # Generated headers (logger_macros.hpp)
      "${CMAKE_CURRENT_SOURCE_DIR}/../src"
      "${CMAKE_CURRENT_SOURCE_DIR}/../include"
      "${CMAKE_CURRENT_SOURCE_DIR}"
      "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include"
      "${CMAKE_BINARY_DIR}/_deps/raft-build/include"
      "${CMAKE_BINARY_DIR}/_deps/rmm-src/include"
      "${CMAKE_BINARY_DIR}/_deps/rmm-build/include"
      "${CMAKE_BINARY_DIR}/_deps/spdlog-src/include"
  )

  target_compile_definitions(cuopttestutils
      PRIVATE
      LIBCUDACXX_ENABLE_EXPERIMENTAL_MEMORY_RESOURCE
  )

  # Add ROCm include path for HIP runtime headers
  if(USE_ROCM)
      target_include_directories(cuopttestutils PRIVATE ${ROCM_PATH}/include)
  endif()

  target_link_libraries(cuopttestutils
      PUBLIC
      ${LIB_TARGET}
      GTest::gmock
      GTest::gtest
  )
  if(NOT DEFINED INSTALL_TARGET OR "${INSTALL_TARGET}" STREQUAL "")
    target_link_options(cuopttestutils PRIVATE -Wl,--enable-new-dtags)
  endif()
endif()


set(CUOPT_TEST_DIR ${CMAKE_CURRENT_SOURCE_DIR})

# ################################################################ ------------------------------------------------------------------
function(ConfigureTest CMAKE_TEST_NAME)
    add_executable(${CMAKE_TEST_NAME} ${ARGN})
    
    # For ROCm: Mark all test source files as HIP
    # Both .cu and .cpp files need HIP compilation because they include RAFT/RMM headers
    # which contain GPU intrinsics (__popcll, atomicAdd, etc.)
    if(USE_ROCM)
        foreach(test_file ${ARGN})
            if(test_file MATCHES "\\.(cu|cpp)$")
                set_source_files_properties(${test_file} PROPERTIES LANGUAGE HIP)
            endif()
        endforeach()
    endif()

    target_include_directories(${CMAKE_TEST_NAME}
        PRIVATE
        "${CMAKE_BINARY_DIR}/_deps/libhipcxx-src/include"  # Must be first for cuda::mr
        "${CMAKE_BINARY_DIR}/include"  # Generated headers (logger_macros.hpp)
        "${CUOPT_TEST_DIR}/../src"
        "${CUOPT_TEST_DIR}/../include"
        "${CUOPT_TEST_DIR}/../libmps_parser/src"
        "${CUOPT_TEST_DIR}"
        "${CMAKE_BINARY_DIR}/_deps/raft-src/cpp/include"
        "${CMAKE_BINARY_DIR}/_deps/raft-build/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-src/include"
        "${CMAKE_BINARY_DIR}/_deps/rmm-build/include"
        "${CMAKE_BINARY_DIR}/_deps/spdlog-src/include"
    )

    target_compile_definitions(${CMAKE_TEST_NAME}
        PRIVATE
        LIBCUDACXX_ENABLE_EXPERIMENTAL_MEMORY_RESOURCE
    )

    # Add ROCm include/lib paths for HIP runtime headers and libraries
    if(USE_ROCM)
        target_include_directories(${CMAKE_TEST_NAME} PRIVATE ${ROCM_PATH}/include)
        target_link_directories(${CMAKE_TEST_NAME} PRIVATE ${ROCM_PATH}/lib)
    endif()

    target_link_libraries(${CMAKE_TEST_NAME}
       PRIVATE
        mps_parser
        ${LIB_TARGET}
        cuopttestutils
        GTest::gmock
        GTest::gmock_main
        GTest::gtest
        GTest::gtest_main
    )
    if(USE_ROCM)
        target_link_libraries(${CMAKE_TEST_NAME} PRIVATE ${CUOPT_PRIVATE_LIBS})
    else()
        target_link_libraries(${CMAKE_TEST_NAME} PRIVATE ${CUOPT_PRIVATE_CUDA_LIBS})
    endif()
    
    # Add compile options for HIP if using ROCm
    if(USE_ROCM)
        target_compile_options(${CMAKE_TEST_NAME}
            PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
            "$<$<COMPILE_LANGUAGE:HIP>:${CUOPT_HIP_FLAGS}>"
        )
    else()
        target_compile_options(${CMAKE_TEST_NAME}
            PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUOPT_CXX_FLAGS}>"
            "$<$<COMPILE_LANGUAGE:CUDA>:${CUOPT_CUDA_FLAGS}>"
        )
    endif()
    
    if(NOT DEFINED INSTALL_TARGET OR "${INSTALL_TARGET}" STREQUAL "")
      target_link_options(${CMAKE_TEST_NAME} PRIVATE -Wl,--enable-new-dtags)
    endif()

    add_test(NAME ${CMAKE_TEST_NAME} COMMAND ${CMAKE_TEST_NAME}
             WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/..)

    install(
        TARGETS ${CMAKE_TEST_NAME}
        COMPONENT testing
        DESTINATION bin/gtests/libcuopt
        EXCLUDE_FROM_ALL
    )
endfunction()


# ####################################################################
# - set rapids dataset path ----------------------------------------------------------------------
if(RAPIDS_DATASET_ROOT_DIR)
    message(STATUS "setting default RAPIDS_DATASET_ROOT_DIR to: ${RAPIDS_DATASET_ROOT_DIR}")
    string(CONCAT CMAKE_C_FLAGS ${CMAKE_C_FLAGS} " -DRAPIDS_DATASET_ROOT_DIR=" "\\\"" ${RAPIDS_DATASET_ROOT_DIR} "\\\"")
    string(CONCAT CMAKE_CXX_FLAGS ${CMAKE_CXX_FLAGS} " -DRAPIDS_DATASET_ROOT_DIR=" "\\\"" ${RAPIDS_DATASET_ROOT_DIR} "\\\"")
    string(CONCAT CMAKE_CUDA_FLAGS ${CMAKE_CUDA_FLAGS} " -DRAPIDS_DATASET_ROOT_DIR=" "\\\"" ${RAPIDS_DATASET_ROOT_DIR} "\\\"")
endif(RAPIDS_DATASET_ROOT_DIR)

# ## test sources
if(BUILD_TESTS)
  if(NOT SKIP_ROUTING_BUILD)
    add_subdirectory(routing)
    add_subdirectory(distance_engine)
    add_subdirectory(examples)
  endif()
  if(NOT BUILD_LP_ONLY)
    add_subdirectory(mip)
  endif()
  add_subdirectory(linear_programming)
  add_subdirectory(dual_simplex)
  add_subdirectory(qp)
  add_subdirectory(utilities)

  enable_testing()
endif()
