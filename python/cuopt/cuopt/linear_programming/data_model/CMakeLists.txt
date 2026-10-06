# cmake-format: off
# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# cmake-format: on

set(cython_sources data_model_wrapper.pyx)
set(linked_libraries cuopt::mps_parser)

rapids_cython_create_modules(SOURCE_FILES "${cython_sources}" LINKED_LIBRARIES "${linked_libraries}" ASSOCIATED_TARGETS cuopt
                                                                               CXX)

# data_model_wrapper's compiled extension module is built with
# INSTALL_RPATH=$ORIGIN, i.e. it expects libmps_parser.so to live right next
# to it in the installed wheel. cuopt::mps_parser (an IMPORTED target --
# see the parent CMakeLists.txt) was never actually copied there, which
# made `from cuopt.linear_programming.data_model import data_model_wrapper`
# (and therefore `import cuopt`) fail at runtime with
# "libmps_parser.so: cannot open shared object file".
include(${CMAKE_SOURCE_DIR}/cmake/Modules/WheelHelpers.cmake)
install_aliased_imported_targets(
    TARGETS cuopt::mps_parser
    DESTINATION cuopt/linear_programming/data_model
)
