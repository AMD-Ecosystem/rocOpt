#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Set ROCOPT_GPU_ARCH for HIP/CMAKE builds.
# Respects a pre-set value.  CI builder agents are CPU-only, so when unset this
# defaults to the multi-arch fat binary list gfx942;gfx950.

if [ -n "${ROCOPT_GPU_ARCH:-}" ]; then
    export ROCOPT_GPU_ARCH
    return 0 2>/dev/null || exit 0
fi

export ROCOPT_GPU_ARCH="${ROCOPT_GPU_ARCH_FALLBACK:-gfx942;gfx950}"
return 0 2>/dev/null || exit 0
