/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#include <cuopt/error.hpp>
#include <utilities/macros.cuh>
#include <raft/util/cudart_utils.hpp>

#include <rmm/cuda_stream_view.hpp>

#pragma once

namespace cuopt {
namespace routing {
namespace detail {

// This is not a thread-safe class, be careful on multi-threading
struct cuda_graph_t {
  void start_capture(rmm::cuda_stream_view stream)
  {
#ifdef __HIP_PLATFORM_AMD__
    // TODO(ROCm): Bypass hipGraph capture — kernels execute directly on the stream.
    // Remove this bypass once hipGraph correctness is verified on ROCm.
    (void)stream;
    capture_started = true;
#else
    // Use ThreadLocal mode to allow multi-threaded batch execution
    // Global mode blocks other streams from performing operations during capture
    RAFT_CUDA_TRY(hipStreamBeginCapture(stream, hipStreamCaptureModeThreadLocal));
    capture_started = true;
#endif
  }

  void end_capture(rmm::cuda_stream_view stream)
  {
    cuopt_assert(capture_started, "start_capture was not called before end_capture!");
    cuopt_expects(capture_started, error_type_t::RuntimeError, "A runtime error occurred!");
#ifdef __HIP_PLATFORM_AMD__
    capture_started = false;
    (void)stream;
#else
    RAFT_CUDA_TRY(hipStreamEndCapture(stream, &graph));
    capture_started = false;
    if (graph_created) {
      // If the graph fails to update, errorNode will be set to the
      // node causing the failure and updateResult will be set to a
      // reason code.
      RAFT_CUDA_TRY(hipGraphExecUpdate(instance, graph, &errorNode, &updateResult));
    }
    // Instantiate during the first iteration or whenever the update
    // fails for any reason
    if (!graph_created || updateResult != hipGraphExecUpdateSuccess) {
      // If a previous update failed, destroy the hipGraphExec_t
      // before re-instantiating it
      if (graph_created) { RAFT_CUDA_TRY(hipGraphExecDestroy(instance)); }
      // Instantiate graphExec from graph. The error node and
      // error message parameters are unused here.
      RAFT_CUDA_TRY(hipGraphInstantiate(&instance, graph));
      graph_created = true;
    }
    RAFT_CUDA_TRY(hipGraphDestroy(graph));
#endif
  }

  void launch_graph(rmm::cuda_stream_view stream)
  {
#ifdef __HIP_PLATFORM_AMD__
    (void)stream;
#else
    RAFT_CUDA_TRY(hipGraphLaunch(instance, stream));
#endif
  }

  bool graph_created   = false;
  bool capture_started = false;
#ifndef __HIP_PLATFORM_AMD__
  hipGraph_t graph;
  hipGraphExec_t instance;
  hipGraphExecUpdateResult updateResult;
  hipGraphNode_t errorNode;
#endif
};

}  // namespace detail
}  // namespace routing
}  // namespace cuopt
