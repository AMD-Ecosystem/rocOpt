.. _parameter-constants:

Parameter Constants
===================

.. role:: py(code)
   :language: c
   :class: highlight

These constants are used as parameter names in the :c:func:`cuOptSetParameter`,
:c:func:`cuOptGetParameter`, and similar functions. For more details on the
available parameters, see the LP/MILP settings section.

``#include <cuopt_c.h>``

.. doxygendefine:: CUOPT_ABSOLUTE_DUAL_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_RELATIVE_DUAL_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_ABSOLUTE_PRIMAL_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_RELATIVE_PRIMAL_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_ABSOLUTE_GAP_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_RELATIVE_GAP_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_INFEASIBILITY_DETECTION
    :project: cuopt

.. doxygendefine:: CUOPT_STRICT_INFEASIBILITY
    :project: cuopt

.. doxygendefine:: CUOPT_PRIMAL_INFEASIBLE_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_DUAL_INFEASIBLE_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_ITERATION_LIMIT
    :project: cuopt

.. doxygendefine:: CUOPT_TIME_LIMIT
    :project: cuopt

.. doxygendefine:: CUOPT_PDLP_SOLVER_MODE
    :project: cuopt

.. doxygendefine:: CUOPT_METHOD
    :project: cuopt

.. doxygendefine:: CUOPT_PER_CONSTRAINT_RESIDUAL
    :project: cuopt

.. doxygendefine:: CUOPT_SAVE_BEST_PRIMAL_SO_FAR
    :project: cuopt

.. doxygendefine:: CUOPT_FIRST_PRIMAL_FEASIBLE
    :project: cuopt

.. doxygendefine:: CUOPT_LOG_FILE
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_ABSOLUTE_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_RELATIVE_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_INTEGRALITY_TOLERANCE
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_ABSOLUTE_GAP
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_RELATIVE_GAP
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_SCALING
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_HEURISTICS_ONLY
    :project: cuopt

.. doxygendefine:: CUOPT_MIP_PRESOLVE
    :project: cuopt

.. doxygendefine:: CUOPT_PRESOLVE
    :project: cuopt

.. doxygendefine:: CUOPT_LOG_TO_CONSOLE
    :project: cuopt

.. doxygendefine:: CUOPT_CROSSOVER
    :project: cuopt

.. doxygendefine:: CUOPT_FOLDING
    :project: cuopt

.. doxygendefine:: CUOPT_AUGMENTED
    :project: cuopt

.. doxygendefine:: CUOPT_DUALIZE
    :project: cuopt

.. doxygendefine:: CUOPT_ORDERING
    :project: cuopt

.. doxygendefine:: CUOPT_ELIMINATE_DENSE_COLUMNS
    :project: cuopt

.. doxygendefine:: CUOPT_CUDSS_DETERMINISTIC
    :project: cuopt

.. doxygendefine:: CUOPT_BARRIER_DUAL_INITIAL_POINT
    :project: cuopt

.. doxygendefine:: CUOPT_DUAL_POSTSOLVE
    :project: cuopt

.. doxygendefine:: CUOPT_SOLUTION_FILE
    :project: cuopt

.. doxygendefine:: CUOPT_NUM_CPU_THREADS
    :project: cuopt

.. doxygendefine:: CUOPT_USER_PROBLEM_FILE
    :project: cuopt
