# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0

"""
ROCm compatibility conftest.py

This file is loaded by pytest BEFORE any test modules are collected/imported.

CRITICAL: cuopt's libcuopt.so and amd-hipdf's libcudf.so each bundle their
own RMM (RAPIDS Memory Manager).  If libcudf.so initialises RMM first (by
importing cudf before cuopt), the two allocators conflict and produce
``free(): invalid size`` → SIGABRT.

The fix is two-fold:
  1. Import cuopt HERE (before any test file is collected) so libcuopt.so
     loads and initialises RMM first.
  2. Never eagerly import cudf/cupy/pylibcudf — use importlib.util.find_spec()
     to check availability without importing, and only register stubs when a
     package is truly missing.
"""

import importlib.util
import os
import sys


# ---------------------------------------------------------------------------
# 0.  Ensure compiled Cython .so files are present in the source tree
#
# When running from the source tree (not pip install -e), the compiled .so
# files from the build directory must be present alongside the .pyx sources
# for imports to work.  Copy them automatically if they're missing.
# ---------------------------------------------------------------------------
_this_dir = os.path.dirname(os.path.abspath(__file__))
_build_glob = os.path.join(_this_dir, "build", "cp*")
import glob as _glob
import shutil as _shutil
for _build_dir in _glob.glob(_build_glob):
    for _root, _dirs, _files in os.walk(_build_dir):
        for _f in _files:
            if _f.endswith(".so"):
                _src = os.path.join(_root, _f)
                _rel = os.path.relpath(_src, _build_dir)
                _dst = os.path.join(_this_dir, _rel)
                if not os.path.exists(_dst):
                    os.makedirs(os.path.dirname(_dst), exist_ok=True)
                    _shutil.copy2(_src, _dst)


# ---------------------------------------------------------------------------
# 0b. Pre-load cuopt so libcuopt.so initialises RMM BEFORE libcudf.so
#
# 22+ routing test files do ``import cudf`` at the top of the file (before
# ``from cuopt import routing``).  When pytest collects those files the cudf
# import would load libcudf.so first, setting up an incompatible RMM.
#
# By importing cuopt now — in conftest, before collection — libcuopt.so gets
# to initialise RMM.  The subsequent ``import cudf`` inside
# vehicle_routing_wrapper.pyx (triggered by the cuopt import) then picks up
# the already-initialised RMM, and later test-file-level ``import cudf``
# statements find cudf already in sys.modules (no-op).
# ---------------------------------------------------------------------------
# Clear COVERAGE_PROCESS_START before importing cuopt.
#
# When --cov is active, pytest-cov sets COVERAGE_PROCESS_START in
# pytest_load_initial_conftests so child processes inherit coverage tracing.
# numba/tests/support.py:66 calls coverage.process_startup() at module-import
# time whenever this env var is set, via the chain:
#   cuopt → cudf → numba.hip → numba.hip.testing → numba.tests.support
# That pushes a second CTracer onto coverage._collectors on top of the one
# pytest-cov already started.  pytest-cov's finish() then asserts
# "_collectors[-1] is self" which fails → INTERNALERROR (exit 3) + no JSON.
#
# Clearing the var here — after pytest-cov's own CTracer is already running
# but before the cuopt import triggers the numba chain — prevents numba from
# seeing it, so only the pytest-cov CTracer is ever created.
os.environ.pop("COVERAGE_PROCESS_START", None)
import cuopt  # noqa: F401, E402


# ---------------------------------------------------------------------------
# 1.  cudf  ->  hipdf  (LAZY – no eager import)
#
# Only register a fallback if the real cudf package is genuinely missing.
# After the ``import cuopt`` above, cudf is almost certainly already in
# sys.modules (loaded by vehicle_routing_wrapper.pyx), so this block is
# typically a no-op.
# ---------------------------------------------------------------------------
if "cudf" not in sys.modules and importlib.util.find_spec("cudf") is None:
    if importlib.util.find_spec("hipdf") is not None:
        import hipdf
        sys.modules["cudf"] = hipdf
    else:
        import pandas
        sys.modules["cudf"] = pandas


# ---------------------------------------------------------------------------
# 2.  cupy  ->  numpy (fallback, LAZY)
#
# CuPy is used in compiled Cython .so files (top-level import).  Only
# register a numpy stub when cupy is genuinely uninstallable.
# ---------------------------------------------------------------------------
if "cupy" not in sys.modules and importlib.util.find_spec("cupy") is None:
    import types
    import numpy as np

    _cupy_stub = types.ModuleType("cupy")
    _cupy_stub.__dict__.update(
        {k: v for k, v in np.__dict__.items() if not k.startswith("_")}
    )
    sys.modules["cupy"] = _cupy_stub


# ---------------------------------------------------------------------------
# 3.  pylibcudf  ->  pylibhipdf  (LAZY)
#
# Only used in cuopt/utilities/utils.py for low-level column construction.
# ---------------------------------------------------------------------------
if "pylibcudf" not in sys.modules and importlib.util.find_spec("pylibcudf") is None:
    if importlib.util.find_spec("pylibhipdf") is not None:
        import pylibhipdf
        sys.modules["pylibcudf"] = pylibhipdf


# ---------------------------------------------------------------------------
# 4.  cuopt_mps_parser  (top-level import)
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


# ---------------------------------------------------------------------------
# 5.  Prevent segfault during interpreter teardown
#
# HIP/ROCm C++ objects (RMM pools, device buffers, solver handles) are
# destroyed by Python's GC in an unpredictable order at interpreter exit.
# If the HIP runtime tears down before all device objects are freed, their
# destructors segfault.  pytest_unconfigure is the very last hook pytest
# calls — after the summary line has been printed — so os._exit() here
# bypasses Python's destructor chain without losing any output.
# ---------------------------------------------------------------------------
def pytest_unconfigure(config):
    os._exit(getattr(config, '_exitstatus', 0))
