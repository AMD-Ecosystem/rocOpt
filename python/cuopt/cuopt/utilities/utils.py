# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import numpy as np

from cuopt.linear_programming.solver.solver_parameters import (
    CUOPT_ABSOLUTE_PRIMAL_TOLERANCE,
    CUOPT_MIP_INTEGRALITY_TOLERANCE,
    CUOPT_RELATIVE_PRIMAL_TOLERANCE,
)


def series_to_pylist(series):
    """Convert a cuDF or pandas Series-like object to a plain Python list.

    On NVIDIA cuOpt, post-solve results are cuDF Series and the canonical
    way to convert them to Python lists is ``series.to_arrow().to_pylist()``.

    On ROCm-DS, ``series_from_buf`` (and other compatibility shims) returns
    a *pandas* Series instead of a cudf Series, because pylibhipdf's
    ``Column.from_rmm_buffer`` aborts at the C level when handed cuOpt RMM
    buffers.  Pandas Series do not have a ``to_arrow`` method, so callers
    that hard-code ``.to_arrow().to_pylist()`` crash with
    ``AttributeError: 'Series' object has no attribute 'to_arrow'``.

    This helper accepts either backend (cuDF Series, pandas Series, or
    anything that exposes ``tolist`` / ``to_pandas``) and always returns a
    Python ``list``.  Use it in place of ``.to_arrow().to_pylist()`` so the
    same code path works on both NVIDIA and AMD GPUs.
    """
    if series is None:
        return None
    to_arrow = getattr(series, "to_arrow", None)
    if callable(to_arrow):
        return to_arrow().to_pylist()
    to_pandas = getattr(series, "to_pandas", None)
    if callable(to_pandas):
        series = to_pandas()
    tolist = getattr(series, "tolist", None)
    if callable(tolist):
        return tolist()
    return list(series)


def series_from_buf(buf, dtype):
    """Helper function to create a pandas Series from a device buffer.

    Parameters
    ----------
    buf : rmm.DeviceBuffer
        The device buffer containing the data
    dtype : pyarrow.dtype or type
        The data type for the Series

    Returns
    -------
    pandas.Series
        A Series built by copying device data to host via numpy.

    Notes
    -----
    The original NVIDIA path used pylibcudf.column.Column.from_rmm_buffer()
    to stay on-device with cudf.  On ROCm-DS the amd-pylibhipdf version of
    that function triggers a C-level abort() when called with cuOpt's RMM
    buffers, which cannot be caught by Python exception handling.  We
    therefore always copy to host, which is safe and sufficient for all
    current cuOpt post-solve result extraction.
    """
    import pandas as pd

    np_dtype = dtype.to_pandas_dtype()
    raw = buf.copy_to_host()
    host_array = np.frombuffer(raw, dtype=np_dtype)
    return pd.Series(host_array)


def validate_variable_bounds(data, settings, solution):
    integrality_tolerance = settings.get_parameter(
        CUOPT_MIP_INTEGRALITY_TOLERANCE
    )
    integrality_tolerance = (
        integrality_tolerance if integrality_tolerance else 1e-5
    )

    if len(data.get_variable_lower_bounds() > 0):
        assert len(solution) == len(data.get_variable_lower_bounds())
        assert np.all(
            solution
            >= (data.get_variable_lower_bounds() - integrality_tolerance)
        )
    if len(data.get_variable_upper_bounds() > 0):
        assert len(solution) == len(data.get_variable_upper_bounds())
        assert np.all(
            solution
            <= (data.get_variable_upper_bounds() + integrality_tolerance)
        )


def validate_constraint_sanity_per_row(
    data, solution, cost, abs_tolerance, rel_tolerance
):
    def combine_finite_abs_bounds(lower, upper):
        val = 0
        if np.isfinite(upper):
            val = max(val, abs(upper))
        if np.isfinite(lower):
            val = max(val, abs(lower))

        return val

    def get_violation(value, lower, upper):
        if value < lower:
            return lower - value
        elif value > upper:
            return value - upper
        else:
            return 0

    values = data.get_constraint_matrix_values()
    offsets = data.get_constraint_matrix_offsets()
    indices = data.get_constraint_matrix_indices()
    constraint_lower_bounds = data.get_constraint_lower_bounds()
    constraint_upper_bounds = data.get_constraint_upper_bounds()
    residual = np.zeros(len(constraint_lower_bounds))

    for i in range(len(offsets) - 1):
        for j in range(offsets[i], offsets[i + 1]):
            residual[i] += values[j] * solution[indices[j]]

    for i in range(len(residual)):
        tolerance = abs_tolerance + combine_finite_abs_bounds(
            constraint_lower_bounds[i],
            constraint_upper_bounds[i] * rel_tolerance,
        )
        violation = get_violation(
            residual[i], constraint_lower_bounds[i], constraint_upper_bounds[i]
        )

        assert violation <= tolerance


def validate_objective_sanity(data, solution, cost, tolerance):
    output = (data.get_objective_coefficients() * solution).sum()

    assert abs(output - cost) <= tolerance


def check_solution(data, setting, solution, cost):
    # check size of the solution matches variable size
    assert len(solution) == len(data.get_variable_types())

    validate_variable_bounds(data, setting, solution)

    abs_tolerance = setting.get_parameter(CUOPT_ABSOLUTE_PRIMAL_TOLERANCE)
    abs_tolerance = abs_tolerance if abs_tolerance else 1e-4

    rel_tolerance = setting.get_parameter(CUOPT_RELATIVE_PRIMAL_TOLERANCE)
    rel_tolerance = rel_tolerance if rel_tolerance else 1e-6

    validate_constraint_sanity_per_row(
        data,
        solution,
        cost,
        abs_tolerance * 1e2,
        rel_tolerance,
    )

    validate_objective_sanity(data, solution, cost, 1e-4)
