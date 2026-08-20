/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2021-2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#pragma once
namespace cuopt {
namespace routing {
namespace detail {

#ifdef __HIP_PLATFORM_AMD__
constexpr int warp_size  = 64;
#else
constexpr int warp_size  = 32;
#endif
constexpr int I_HALF_MAX = 65504;  // highest positive value representable by half
                                   // there is no numeric_limits implementation of half
}  // namespace detail
}  // namespace routing
}  // namespace cuopt
