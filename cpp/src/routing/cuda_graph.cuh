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
    // Use ThreadLocal mode to allow multi-threaded batch execution
    // Global mode blocks other streams from performing operations during capture
    RAFT_CUDA_TRY(hipStreamBeginCapture(stream, hipStreamCaptureModeThreadLocal));
    capture_started = true;
  }

  void end_capture(rmm::cuda_stream_view stream)
  {
    cuopt_assert(capture_started, "start_capture was not called before end_capture!");
    cuopt_expects(capture_started, error_type_t::RuntimeError, "A runtime error occurred!");
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
#ifdef __HIP_PLATFORM_AMD__
      // HIP requires 5 arguments for hipGraphInstantiate
      RAFT_CUDA_TRY(hipGraphInstantiate(&instance, graph, nullptr, nullptr, 0));
#else
      RAFT_CUDA_TRY(hipGraphInstantiate(&instance, graph));
#endif
      graph_created = true;
    }
    RAFT_CUDA_TRY(hipGraphDestroy(graph));
  }

  void launch_graph(rmm::cuda_stream_view stream) { RAFT_CUDA_TRY(hipGraphLaunch(instance, stream)); }

  bool graph_created   = false;
  bool capture_started = false;
  hipGraph_t graph;
  hipGraphExec_t instance;
  hipGraphExecUpdateResult updateResult;
  hipGraphNode_t errorNode;
};

}  // namespace detail
}  // namespace routing
}  // namespace cuopt
