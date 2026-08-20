Problem Construction and Destruction
====================================

.. role:: py(code)
   :language: c
   :class: highlight

An optimization problem is represented via a ``cuOptOptimizationProblem``.

``#include <cuopt_c.h>``

.. doxygentypedef:: cuOptOptimizationProblem
    :project: cuopt

Optimization problems can be created via three different functions.

.. doxygenfunction:: cuOptReadProblem
    :project: cuopt

.. doxygenfunction:: cuOptCreateProblem
    :project: cuopt

.. doxygenfunction:: cuOptCreateRangedProblem
    :project: cuopt

An optimization problem must be destroyed with the following function.

.. doxygenfunction:: cuOptDestroyProblem
    :project: cuopt
