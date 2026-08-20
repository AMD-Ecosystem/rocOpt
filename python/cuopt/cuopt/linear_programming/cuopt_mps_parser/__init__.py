# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

def __getattr__(name):
    # Lazy import to break circular dependency: __init__ -> parser ->
    # parser_wrapper.so -> cuopt_mps_parser.utilities -> __init__ (not done).
    # By deferring, __init__.py finishes first, so the .so can resolve
    # cuopt_mps_parser.utilities without hitting a partial module.
    if name in ("ParseMps", "toDict"):
        from cuopt_mps_parser.parser import ParseMps, toDict
        globals()["ParseMps"] = ParseMps
        globals()["toDict"] = toDict
        return globals()[name]
    raise AttributeError(f"module 'cuopt_mps_parser' has no attribute {name}")
