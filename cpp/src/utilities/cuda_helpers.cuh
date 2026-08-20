#include "hip/hip_runtime.h"
/* clang-format off */
/*
 * SPDX-FileCopyrightText: Copyright (c) 2022-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
/* clang-format on */

#pragma once

#define CUOPT_KERNEL_DEBUG 0
#if CUOPT_KERNEL_DEBUG
#define CUOPT_KERNEL_TRACE(name, ...) \
  do { fprintf(stderr, "[KERNEL] " name " " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
#define CUOPT_KERNEL_SYNC_CHECK(name, stream) \
  do { \
    hipStreamSynchronize(stream); \
    auto _err = hipGetLastError(); \
    if (_err != hipSuccess) fprintf(stderr, "[CRASH] " name ": %s\n", hipGetErrorString(_err)); \
    else fprintf(stderr, "[KERNEL] " name " OK\n"); \
  } while(0)
#else
#define CUOPT_KERNEL_TRACE(name, ...)
#define CUOPT_KERNEL_SYNC_CHECK(name, stream)
#endif

#include <utilities/macros.cuh>

#include <thrust/host_vector.h>
#include <mutex>
#include <raft/core/device_span.hpp>
#include <raft/util/cuda_utils.cuh>
#include <raft/util/cudart_utils.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/mr/device/cuda_async_memory_resource.hpp>
#include <rmm/mr/device/limiting_resource_adaptor.hpp>
#include <unordered_map>

// Block-scoped atomics for HIP using libhipcxx
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_PLATFORM_HCC__) || defined(__HIPCC__)
#include <cuda/atomic>

// Block-scoped atomic operations using libhipcxx
template <typename T>
__device__ inline T atomicAdd_block_hip(T* addr, T val) {
  cuda::atomic_ref<T, cuda::thread_scope_block> ref(*addr);
  return ref.fetch_add(val, cuda::memory_order_relaxed);
}

template <typename T>
__device__ inline T atomicCAS_block_hip(T* addr, T compare, T val) {
  cuda::atomic_ref<T, cuda::thread_scope_block> ref(*addr);
  ref.compare_exchange_strong(compare, val, cuda::memory_order_relaxed);
  return compare;
}

template <typename T>
__device__ inline T atomicExch_block_hip(T* addr, T val) {
  cuda::atomic_ref<T, cuda::thread_scope_block> ref(*addr);
  return ref.exchange(val, cuda::memory_order_relaxed);
}

template <typename T>
__device__ inline T atomicMax_block_hip(T* addr, T val) {
  cuda::atomic_ref<T, cuda::thread_scope_block> ref(*addr);
  return ref.fetch_max(val, cuda::memory_order_relaxed);
}

template <typename T>
__device__ inline T atomicMin_block_hip(T* addr, T val) {
  cuda::atomic_ref<T, cuda::thread_scope_block> ref(*addr);
  return ref.fetch_min(val, cuda::memory_order_relaxed);
}

#ifndef atomicAdd_block
#define atomicAdd_block(addr, val) atomicAdd_block_hip(addr, val)
#endif
#ifndef atomicCAS_block
#define atomicCAS_block(addr, cmp, val) atomicCAS_block_hip(addr, cmp, val)
#endif
#ifndef atomicExch_block
#define atomicExch_block(addr, val) atomicExch_block_hip(addr, val)
#endif
#ifndef atomicMax_block
#define atomicMax_block(addr, val) atomicMax_block_hip(addr, val)
#endif
#ifndef atomicMin_block
#define atomicMin_block(addr, val) atomicMin_block_hip(addr, val)
#endif
#endif // HIP platform check

namespace cuopt {

#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 700)
#error "cuOpt is only supported on Volta and newer architectures"
#endif

/** helper macro for device inlined functions */
#define DI  inline __device__
#define HDI inline __host__ __device__
#define HD  __host__ __device__

DI int popcount_active_mask()
{
#if defined(__HIP_PLATFORM_AMD__)
  return __popcll(__activemask());
#else
  return __popc(__activemask());
#endif
}

/**
 * For Pascal independent thread scheduling is not supported so we are using a seperate
 * add version. This version will return when there are duplicates instead of
 * udapting the key with the min value. Another approach would be to use a 64 bit
 * representation for values and predecessors and use atomicMin. This comes with
 * accuracy trade-offs. Hence the seperate add function for Pascal.
 **/
template <typename i_t>
DI bool try_acquire_lock(i_t* lock)
{
  auto res = atomicCAS(lock, 0, 1);
  if (res == 0) { __threadfence(); return true; }
  return false;
}

template <typename i_t>
DI bool acquire_lock(i_t* lock)
{
#if defined(__HIP_PLATFORM_AMD__)
  if (atomicCAS(lock, 0, 1) == 0) {
    __threadfence();
    return true;
  }
  return false;
#elif defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 700)
  auto res = atomicCAS(lock, 0, 1);
  __threadfence();
  return res == 0;
#else
  while (atomicCAS(lock, 0, 1)) {
    __nanosleep(100);
  }
  __threadfence();
  return true;
#endif
}

template <typename i_t>
DI void release_lock(i_t* lock)
{
  __threadfence();
  atomicExch(lock, 0);
}

template <typename i_t>
DI bool try_acquire_lock_block(i_t* lock)
{
  auto res = atomicCAS_block(lock, 0, 1);
  __threadfence_block();
  return res == 0;
}

template <typename i_t>
DI bool acquire_lock_block(i_t* lock)
{
#if defined(__HIP_PLATFORM_AMD__)
  if (atomicCAS_block(lock, 0, 1) == 0) {
    __threadfence_block();
    return true;
  }
  return false;
#elif defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 700)
  return try_acquire_lock_block(lock);
#else
  while (atomicCAS_block(lock, 0, 1)) {
    __nanosleep(100);
  }
  __threadfence_block();
  return true;
#endif
}

template <typename i_t>
DI void release_lock_block(i_t* lock)
{
  __threadfence_block();
  atomicExch_block(lock, 0);
}

// Lock wrapper that retries until the lock is acquired.
// On AMD the try-lock may fail under contention because a blocking spin
// would deadlock threads within the same wavefront.  Retrying at the
// caller level avoids this: the lock holder releases inside the loop body
// (before the for-loop reconvergence point), so other threads in the same
// wavefront see the lock freed on their next iteration.
template <typename i_t, typename F>
DI void with_lock(i_t* lock, F&& critical_section)
{
#if defined(__HIP_PLATFORM_AMD__)
  for (int _retry = 0; _retry < 4096; ++_retry) {
    if (acquire_lock(lock)) {
      critical_section();
      release_lock(lock);
      return;
    }
    __builtin_amdgcn_s_sleep(8);
  }
#else
  if (acquire_lock(lock)) {
    critical_section();
    release_lock(lock);
  }
#endif
}

template <typename i_t, typename F>
DI void with_lock_block(i_t* lock, F&& critical_section)
{
#if defined(__HIP_PLATFORM_AMD__)
  for (int _retry = 0; _retry < 4096; ++_retry) {
    if (acquire_lock_block(lock)) {
      critical_section();
      release_lock_block(lock);
      return;
    }
    __builtin_amdgcn_s_sleep(8);
  }
#else
  if (acquire_lock_block(lock)) {
    critical_section();
    release_lock_block(lock);
  }
#endif
}

template <typename T>
DI void init_shmem(T& shmem, T val)
{
  if (threadIdx.x == 0) { shmem = val; }
}

template <typename T>
DI void init_block_shmem(T* shmem, T val, size_t size)
{
  for (auto i = threadIdx.x; i < size; i += blockDim.x) {
    shmem[i] = val;
  }
}

template <typename T>
DI void init_block_shmem(raft::device_span<T> sh_span, T val)
{
  init_block_shmem(sh_span.data(), val, sh_span.size());
}

template <typename T>
DI void block_sequence(T* arr, const size_t size)
{
  for (auto i = threadIdx.x; i < size; i += blockDim.x) {
    arr[i] = i;
  }
}

template <typename T>
DI void block_copy(T* dst, const T* src, const size_t size)
{
  for (auto i = threadIdx.x; i < size; i += blockDim.x) {
    dst[i] = src[i];
  }
}

template <typename T>
DI void block_copy(raft::device_span<T> dst,
                   const raft::device_span<const T> src,
                   const size_t size)
{
  cuopt_assert(src.size() >= size, "block_copy::src does not have the sufficient size");
  cuopt_assert(dst.size() >= size, "block_copy::dst does not have the sufficient size");
  block_copy(dst.data(), src.data(), size);
}

template <typename T>
DI void block_copy(raft::device_span<T> dst, const raft::device_span<T> src, const size_t size)
{
  cuopt_assert(src.size() >= size, "block_copy::src does not have the sufficient size");
  cuopt_assert(dst.size() >= size, "block_copy::dst does not have the sufficient size");
  block_copy(dst.data(), src.data(), size);
}

template <typename T>
DI void block_copy(raft::device_span<T> dst, const raft::device_span<T> src)
{
  cuopt_assert(dst.size() >= src.size(), "");
  block_copy(dst, src, src.size());
}

template <typename i_t>
i_t next_pow2(i_t val)
{
  return 1 << (raft::log2(val) + 1);
}

// FIXME:: handle alignment when dealing with different sized precisions
template <typename T, typename i_t>
static DI thrust::tuple<raft::device_span<T>, i_t*> wrap_ptr_as_span(i_t* shmem, size_t sz)
{
  T* sh_ptr = (T*)shmem;
  auto s    = raft::device_span<T>{sh_ptr, sz};

  sh_ptr = sh_ptr + sz;
  return thrust::make_tuple(s, (i_t*)sh_ptr);
}

template <class To, class From>
HDI To bit_cast(const From& src)
{
  static_assert(sizeof(To) == sizeof(From));
  return *(To*)(&src);
}

inline int get_device_max_shmem_per_block()
{
  int device_id = 0;
  RAFT_CUDA_TRY(hipGetDevice(&device_id));
  int max_shmem = 0;
  RAFT_CUDA_TRY(
    hipDeviceGetAttribute(&max_shmem, hipDeviceAttributeMaxSharedMemoryPerBlock, device_id));
  return max_shmem;
}

template <typename Function>
inline bool set_shmem_of_kernel(Function* function, size_t dynamic_request_size)
{
  static std::mutex mtx;
  static std::unordered_map<Function*, size_t> shmem_sizes;

  if (dynamic_request_size != 0) {
    dynamic_request_size = raft::alignTo(dynamic_request_size, size_t(1024));
    size_t current_size  = shmem_sizes[function];
    if (dynamic_request_size > current_size) {
      std::lock_guard<std::mutex> lock(mtx);
      current_size = shmem_sizes[function];

      if (dynamic_request_size > current_size) {
#if defined(__HIP_PLATFORM_AMD__)
        int device_id = 0;
        RAFT_CUDA_TRY(hipGetDevice(&device_id));
        int max_shmem = 0;
        RAFT_CUDA_TRY(hipDeviceGetAttribute(
          &max_shmem, hipDeviceAttributeMaxSharedMemoryPerBlock, device_id));
        hipFuncAttributes func_attr{};
        hipFuncGetAttributes(&func_attr, reinterpret_cast<const void*>(function));
        int static_shmem = func_attr.sharedSizeBytes;
        int available     = max_shmem - static_shmem;
        if (available < 0 || static_cast<int>(dynamic_request_size) > available) {
          fprintf(stderr,
                  "[cuopt] WARNING: kernel %p skipped: needs %zu + %d = %zu bytes shmem, "
                  "device max = %d\n",
                  reinterpret_cast<const void*>(function),
                  dynamic_request_size,
                  static_shmem,
                  dynamic_request_size + static_shmem,
                  max_shmem);
          return false;
        }
        auto attr_err = hipFuncSetAttribute(reinterpret_cast<const void*>(function),
                                            hipFuncAttributeMaxDynamicSharedMemorySize,
                                            dynamic_request_size);
        if (attr_err != hipSuccess) {
          hipGetLastError();
        }
#else
        RAFT_CUDA_TRY(hipFuncSetAttribute(reinterpret_cast<const void*>(
          function), hipFuncAttributeMaxDynamicSharedMemorySize, dynamic_request_size));
#endif
        shmem_sizes[function] = dynamic_request_size;
        return (hipSuccess == hipGetLastError());
      }
    }
  }
  return true;
}

template <typename T>
DI void sorted_insert(T* array, T item, int curr_size, int max_size)
{
  for (int i = curr_size - 1; i >= 0; --i) {
    if (i == max_size - 1) continue;
    if (array[i] < item) {
      array[i + 1] = item;
      return;
    } else {
      array[i + 1] = array[i];
    }
  }
  array[0] = item;
}

inline size_t get_device_memory_size()
{
  // Otherwise, we need to get the free memory from the device
  size_t free_mem, total_mem;
  RAFT_CUDA_TRY(hipMemGetInfo(&free_mem, &total_mem));

  auto res = rmm::mr::get_current_device_resource();
  auto limiting_adaptor =
    dynamic_cast<rmm::mr::limiting_resource_adaptor<rmm::mr::cuda_async_memory_resource>*>(res);
  // Did we specifiy an explicit memory limit?
  if (limiting_adaptor) {
    printf("limiting_adaptor->get_allocation_limit(): %fMiB\n",
           limiting_adaptor->get_allocation_limit() / (double)1e6);
    printf("used_mem: %fMiB\n", limiting_adaptor->get_allocated_bytes() / (double)1e6);
    printf("free_mem: %fMiB\n",
           (limiting_adaptor->get_allocation_limit() - limiting_adaptor->get_allocated_bytes()) /
             (double)1e6);
    return std::min(total_mem, limiting_adaptor->get_allocation_limit());
  } else {
    return total_mem;
  }
}

}  // namespace cuopt
