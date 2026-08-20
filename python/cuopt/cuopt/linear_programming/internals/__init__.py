# SPDX-FileCopyrightText: Copyright (c) 2020-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

try:
    from cuopt.linear_programming.internals.internals import (
        GetSolutionCallback,
        SetSolutionCallback,
    )
except ImportError:
    import warnings
    warnings.warn(
        "cuopt.linear_programming.internals native extension not found. "
        "MIP solution callbacks will not be available. "
        "Rebuild with: ./build.sh cuopt",
        stacklevel=2,
    )
    GetSolutionCallback = None
    SetSolutionCallback = None
