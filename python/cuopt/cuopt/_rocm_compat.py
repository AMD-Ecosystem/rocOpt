# SPDX-FileCopyrightText: Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""ROCm-DS compatibility shims for cuOpt.

Background
----------
On NVIDIA cuOpt, all post-solve results are returned as :class:`cudf.Series`
objects, which expose a ``.to_arrow()`` method that returns a
:class:`pyarrow.Array`.  cuOpt's Python layer is full of call patterns like::

    series.to_arrow().to_pylist()

On ROCm-DS, several internal helpers (e.g. ``cuopt.utilities.series_from_buf``)
fall back to returning *pandas* Series rather than cuDF Series, because
pylibhipdf's ``Column.from_rmm_buffer`` aborts at the C level when handed
cuOpt's RMM device buffers.  Pandas Series do not have ``to_arrow``, so every
``.to_arrow().to_pylist()`` call site crashes with::

    AttributeError: 'Series' object has no attribute 'to_arrow'

Touching all of those call sites would be a large, mechanical diff; instead we
install a small compatibility shim that gives :class:`pandas.Series` and
:class:`pandas.Index` a ``to_arrow`` method matching the cuDF semantics
(returns a :class:`pyarrow.Array`).  This is only installed when the attribute
is missing, so it is a no-op on systems where cuDF (or any future pandas
version) already provides it.

Going forward, prefer :func:`cuopt.utilities.series_to_pylist`, which works
without relying on the monkey patch.
"""

from __future__ import annotations


def _install_pandas_to_arrow_shim() -> None:
    try:
        import pandas as pd
        import pyarrow as pa
    except Exception:
        return

    def _series_to_arrow(self):
        return pa.Array.from_pandas(self)

    def _index_to_arrow(self):
        return pa.Array.from_pandas(self.to_series())

    if not hasattr(pd.Series, "to_arrow"):
        pd.Series.to_arrow = _series_to_arrow  # type: ignore[attr-defined]
    if not hasattr(pd.Index, "to_arrow"):
        pd.Index.to_arrow = _index_to_arrow  # type: ignore[attr-defined]


_install_pandas_to_arrow_shim()
