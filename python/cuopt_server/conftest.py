# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0

"""Clears COVERAGE_PROCESS_START before test collection begins.

pytest-cov sets this env var in pytest_load_initial_conftests so that child
processes inherit coverage tracing.  numba/tests/support.py:66 calls
coverage.process_startup() at module-import time via the chain:

    cuopt → cudf → numba.hip → numba.hip.testing → numba.tests.support

Unlike the cuopt suite (which has an explicit ``import cuopt`` in its
conftest.py), the cuopt_server suite has no such eager import.  Instead,
test_lp.py (and other test files) import cuopt at module level; this import
runs during pytest_collection → _importtestmodule for each test file.  By that
point COVERAGE_PROCESS_START is still set, pushing a second CTracer onto
coverage._collectors and causing INTERNALERROR (exit 3) with no JSON produced.

This conftest.py is loaded during pytest_load_initial_conftests — before any
test module is collected or imported — so the env var is already cleared when
test_lp.py is imported during collection, and numba finds nothing to act on.
"""

import os

os.environ.pop("COVERAGE_PROCESS_START", None)
