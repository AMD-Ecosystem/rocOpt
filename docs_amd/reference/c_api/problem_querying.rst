Querying an Optimization Problem
================================

.. role:: py(code)
   :language: c
   :class: highlight

The following functions may be used to get information about a
``cuOptOptimizationProblem``.

``#include <cuopt_c.h>``

.. doxygenfunction:: cuOptGetNumConstraints
    :project: cuopt

.. doxygenfunction:: cuOptGetNumVariables
    :project: cuopt

.. doxygenfunction:: cuOptGetObjectiveSense
    :project: cuopt

.. doxygenfunction:: cuOptGetObjectiveOffset
    :project: cuopt

.. doxygenfunction:: cuOptGetObjectiveCoefficients
    :project: cuopt

.. doxygenfunction:: cuOptGetNumNonZeros
    :project: cuopt

.. doxygenfunction:: cuOptGetConstraintMatrix
    :project: cuopt

.. doxygenfunction:: cuOptGetConstraintSense
    :project: cuopt

.. doxygenfunction:: cuOptGetConstraintRightHandSide
    :project: cuopt

.. doxygenfunction:: cuOptGetConstraintLowerBounds
    :project: cuopt

.. doxygenfunction:: cuOptGetConstraintUpperBounds
    :project: cuopt

.. doxygenfunction:: cuOptGetVariableLowerBounds
    :project: cuopt

.. doxygenfunction:: cuOptGetVariableUpperBounds
    :project: cuopt

.. doxygenfunction:: cuOptGetVariableTypes
    :project: cuopt

.. doxygenfunction:: cuOptIsMIP
    :project: cuopt
