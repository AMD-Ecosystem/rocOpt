Termination Status Constants
============================

.. role:: py(code)
   :language: c
   :class: highlight

These constants define the termination status received from the
:c:func:`cuOptGetTerminationStatus` function.

``#include <cuopt_c.h>``

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_NO_TERMINATION
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_OPTIMAL
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_INFEASIBLE
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_UNBOUNDED
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_ITERATION_LIMIT
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_TIME_LIMIT
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_NUMERICAL_ERROR
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_PRIMAL_FEASIBLE
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_FEASIBLE_FOUND
    :project: cuopt

.. doxygendefine:: CUOPT_TERIMINATION_STATUS_CONCURRENT_LIMIT
    :project: cuopt
