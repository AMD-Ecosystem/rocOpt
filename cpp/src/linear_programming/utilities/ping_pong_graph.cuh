/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#pragma once

#include <hip/hip_runtime.h>

namespace cuopt::linear_programming::detail {

// Helper class to capture and launch CUDA graph
// No additional checks for safe usage (calling launch() before initializing the graph) use with
// caution Binary part is because in pdlp we swap pointers instead of copying vectors to accept a
// valid pdhg step So every odd pdlp step it's one graph, every even step it's another graph
template <typename i_t>
class ping_pong_graph_t {
 public:
  ping_pong_graph_t(rmm::cuda_stream_view stream_view, bool is_batch_mode = false)
    : stream_view_(stream_view), is_batch_mode_(is_batch_mode)
  {
  }

  ~ping_pong_graph_t()
  {
    if (!is_batch_mode_) {
      if (even_initialized) { RAFT_CUDA_TRY_NO_THROW(hipGraphExecDestroy(even_instance)); }
      if (odd_initialized) { RAFT_CUDA_TRY_NO_THROW(hipGraphExecDestroy(odd_instance)); }
    }
  }

  void start_capture(i_t total_pdlp_iterations)
  {
    if (!is_batch_mode_) {
      if (total_pdlp_iterations % 2 == 0 && !even_initialized) {
        RAFT_CUDA_TRY(
          hipStreamBeginCapture(stream_view_.value(), hipStreamCaptureModeThreadLocal));
      } else if (total_pdlp_iterations % 2 == 1 && !odd_initialized) {
        RAFT_CUDA_TRY(
          hipStreamBeginCapture(stream_view_.value(), hipStreamCaptureModeThreadLocal));
      }
    }
  }

  void end_capture(i_t total_pdlp_iterations)
  {
    if (!is_batch_mode_) {
      if (total_pdlp_iterations % 2 == 0 && !even_initialized) {
        RAFT_CUDA_TRY(hipStreamEndCapture(stream_view_.value(), &even_graph));
#ifdef __HIP_PLATFORM_AMD__
        RAFT_CUDA_TRY(hipGraphInstantiate(&even_instance, even_graph, nullptr, nullptr, 0));
#else
        RAFT_CUDA_TRY(hipGraphInstantiate(&even_instance, even_graph));
#endif
        even_initialized = true;
        RAFT_CUDA_TRY_NO_THROW(hipGraphDestroy(even_graph));
      } else if (total_pdlp_iterations % 2 == 1 && !odd_initialized) {
        RAFT_CUDA_TRY(hipStreamEndCapture(stream_view_.value(), &odd_graph));
#ifdef __HIP_PLATFORM_AMD__
        RAFT_CUDA_TRY(hipGraphInstantiate(&odd_instance, odd_graph, nullptr, nullptr, 0));
#else
        RAFT_CUDA_TRY(hipGraphInstantiate(&odd_instance, odd_graph));
#endif
        odd_initialized = true;
        RAFT_CUDA_TRY_NO_THROW(hipGraphDestroy(odd_graph));
      }
    }
  }

  void launch(i_t total_pdlp_iterations)
  {
    if (!is_batch_mode_) {
      if (total_pdlp_iterations % 2 == 0 && even_initialized) {
        RAFT_CUDA_TRY(hipGraphLaunch(even_instance, stream_view_.value()));
      } else if (total_pdlp_iterations % 2 == 1 && odd_initialized) {
        RAFT_CUDA_TRY(hipGraphLaunch(odd_instance, stream_view_.value()));
      }
    }
  }

  bool is_initialized(i_t total_pdlp_iterations)
  {
    if (!is_batch_mode_) {
      return (total_pdlp_iterations % 2 == 0 && even_initialized) ||
             (total_pdlp_iterations % 2 == 1 && odd_initialized);
    }
    return false;
  }

 private:
  hipGraph_t even_graph;
  hipGraph_t odd_graph;
  hipGraphExec_t even_instance;
  hipGraphExec_t odd_instance;
  rmm::cuda_stream_view stream_view_;
  bool even_initialized{false};
  bool odd_initialized{false};
  // Temporary fix to disable cuda graph in batch mode
  bool is_batch_mode_{false};
};
}  // namespace cuopt::linear_programming::detail
