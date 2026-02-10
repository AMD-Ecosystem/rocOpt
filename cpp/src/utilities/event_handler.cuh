/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2024-2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */
#pragma once

#include <hip/hip_runtime.h>
#include <raft/util/cuda_utils.cuh>
#include <rmm/cuda_stream_view.hpp>

namespace cuopt {

class event_handler_t {
 public:
  event_handler_t() { RAFT_CUDA_TRY(hipEventCreate(&event_)); }
  event_handler_t(unsigned int flags) { RAFT_CUDA_TRY(hipEventCreateWithFlags(&event_, flags)); }
  ~event_handler_t() { RAFT_CUDA_TRY_NO_THROW(hipEventDestroy(event_)); }

  event_handler_t(const event_handler_t&)            = delete;
  event_handler_t& operator=(const event_handler_t&) = delete;

  void record(rmm::cuda_stream_view stream_view)
  {
    RAFT_CUDA_TRY(hipEventRecord(event_, stream_view));
  }

  void record_with_flags(rmm::cuda_stream_view stream_view, int flags)
  {
    RAFT_CUDA_TRY(hipEventRecordWithFlags(event_, stream_view, flags));
  }

  void stream_wait(rmm::cuda_stream_view stream_view)
  {
    RAFT_CUDA_TRY(hipStreamWaitEvent(stream_view, event_));
  }

  float elapsed_time_since_ms(const event_handler_t& start)
  {
    float ms;
    // TODO: use cudaEventElapsedTime_v2 with CUDA 12.8?
    RAFT_CUDA_TRY(hipEventElapsedTime(&ms, start.event_, event_));
    return ms;
  }

  void synchronize() { RAFT_CUDA_TRY(hipEventSynchronize(event_)); }

 private:
  hipEvent_t event_;
};
}  // namespace cuopt
