Accessing a Solution
====================

.. role:: py(code)
   :language: c
   :class: highlight

The output of a solve is a ``cuOptSolution`` object.

``#include <cuopt_c.h>``

.. doxygentypedef:: cuOptSolution
    :project: cuopt

The following functions may be used to access information from a
``cuOptSolution``.

.. doxygenfunction:: cuOptGetTerminationStatus
    :project: cuopt

.. doxygenfunction:: cuOptGetErrorStatus
    :project: cuopt

.. doxygenfunction:: cuOptGetErrorString
    :project: cuopt

.. doxygenfunction:: cuOptGetPrimalSolution
    :project: cuopt

.. doxygenfunction:: cuOptGetObjectiveValue
    :project: cuopt

.. doxygenfunction:: cuOptGetSolveTime
    :project: cuopt

.. doxygenfunction:: cuOptGetMIPGap
    :project: cuopt

.. doxygenfunction:: cuOptGetSolutionBound
    :project: cuopt

.. doxygenfunction:: cuOptGetDualSolution
    :project: cuopt

.. doxygenfunction:: cuOptGetDualObjectiveValue
    :project: cuopt

.. doxygenfunction:: cuOptGetReducedCosts
    :project: cuopt

When you are finished with a ``cuOptSolution`` object you should destroy it
with the following function.

.. doxygenfunction:: cuOptDestroySolution
    :project: cuopt
