Solver Settings Object
======================

.. role:: py(code)
   :language: c
   :class: highlight

Settings are used to configure the LP/MIP solvers. All settings are stored in a
``cuOptSolverSettings`` object.

``#include <cuopt_c.h>``

.. doxygentypedef:: cuOptSolverSettings
    :project: cuopt

A ``cuOptSolverSettings`` object is created with ``cuOptCreateSolverSettings``.

.. doxygenfunction:: cuOptCreateSolverSettings
    :project: cuopt

When you are done with a solve you should destroy a ``cuOptSolverSettings``
object with the following function.

.. doxygenfunction:: cuOptDestroySolverSettings
    :project: cuopt
