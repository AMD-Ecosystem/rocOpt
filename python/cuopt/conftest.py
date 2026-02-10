# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0

"""
ROCm compatibility conftest.py

This file is loaded by pytest BEFORE any test modules are collected/imported.
It patches sys.modules so that NVIDIA-specific Python package names resolve
to their ROCm-DS equivalents (which are already installed).

Mapping:
  cudf          -> hipdf      (ROCm-DS GPU DataFrame library)
  pylibcudf     -> pylibhipdf (ROCm-DS low-level cuDF bindings)
  cuopt_mps_parser -> added to sys.path so the subpackage is importable
                      as a top-level module (matches upstream test expectations)
"""

import os
import sys


# ---------------------------------------------------------------------------
# 1.  cudf  ->  hipdf
#
# hipDF is the ROCm-DS equivalent of NVIDIA cuDF.  Both expose the same
# DataFrame / Series API, so existing code that does ``import cudf`` works
# unchanged once we redirect the module name.
# ---------------------------------------------------------------------------
if "cudf" not in sys.modules:
    try:
        import cudf  # noqa: F401  – use the real thing if available
    except ImportError:
        try:
            import hipdf

            sys.modules["cudf"] = hipdf
        except ImportError:
            # Last-resort fallback: cudf's API is modelled on pandas.
            # This allows test *collection* to succeed even without a GPU
            # DataFrame library, though tests that rely on GPU features
            # will fail at runtime.
            import pandas

            sys.modules["cudf"] = pandas


# ---------------------------------------------------------------------------
# 2.  pylibcudf  ->  pylibhipdf
#
# Only used in cuopt/utilities/utils.py for low-level column construction.
# ---------------------------------------------------------------------------
if "pylibcudf" not in sys.modules:
    try:
        import pylibcudf  # noqa: F401
    except ImportError:
        try:
            import pylibhipdf

            sys.modules["pylibcudf"] = pylibhipdf
        except ImportError:
            pass  # tests that need this will fail at runtime with a clear error


# ---------------------------------------------------------------------------
# 3.  cuopt_mps_parser  (top-level import)
#
# The LP tests do ``import cuopt_mps_parser`` as a top-level package, but
# the code lives at  cuopt/linear_programming/cuopt_mps_parser/.
# Add the parent directory to sys.path so Python can find it.
# (The Cython extension parser_wrapper must be compiled for full
# functionality; this only fixes the *discovery* of the pure-Python parts.)
# ---------------------------------------------------------------------------
_mps_parser_parent = os.path.join(
    os.path.dirname(__file__), "cuopt", "linear_programming"
)
if _mps_parser_parent not in sys.path:
    sys.path.insert(0, _mps_parser_parent)
