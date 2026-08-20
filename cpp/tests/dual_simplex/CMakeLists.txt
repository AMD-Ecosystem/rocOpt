# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

ConfigureTest(DUAL_SIMPLEX_TEST
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/solve.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/solve_barrier.cu
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/folding.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/sparse_matrix.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/vector_math.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/basis_updates.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/initial_basis.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/primal.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/unit_tests/crossover.cpp
)
