#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
#
# Set HCC_AMDGPU_TARGET for CuPy/Numba JIT from the active AMD GPU at test/runtime.
# Safe to source on GPU-less hosts (no-op).  Respects a pre-set value.

if [ -n "${HCC_AMDGPU_TARGET:-}" ]; then
    export HCC_AMDGPU_TARGET
    return 0 2>/dev/null || exit 0
fi

if ! command -v rocminfo >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

# Match only agent name lines ("Name:    gfx950"), not ISA strings.
_detected=$(
    { rocminfo 2>/dev/null || true; } | awk '/^[[:space:]]*Name:[[:space:]]+gfx[0-9a-fA-F]+[[:space:]]*$/ {print $2}' \
        | sort -u | head -1 || true
)
if [ -n "${_detected}" ]; then
    export HCC_AMDGPU_TARGET="${_detected}"
fi
unset _detected

return 0 2>/dev/null || exit 0
