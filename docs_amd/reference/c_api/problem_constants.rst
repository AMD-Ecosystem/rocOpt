Problem Definition Constants
============================

.. role:: py(code)
   :language: c
   :class: highlight

Certain constants are needed to define an optimization problem.

``#include <cuopt_c.h>``

Objective Sense Constants
-------------------------

These constants are used to define the objective sense in the
:c:func:`cuOptCreateProblem` and :c:func:`cuOptCreateRangedProblem` functions.

.. doxygendefine:: CUOPT_MINIMIZE
    :project: cuopt

.. doxygendefine:: CUOPT_MAXIMIZE
    :project: cuopt

Constraint Sense Constants
--------------------------

These constants are used to define the constraint sense in the
:c:func:`cuOptCreateProblem` and :c:func:`cuOptCreateRangedProblem` functions.

.. doxygendefine:: CUOPT_LESS_THAN
    :project: cuopt

.. doxygendefine:: CUOPT_GREATER_THAN
    :project: cuopt

.. doxygendefine:: CUOPT_EQUAL
    :project: cuopt

Variable Type Constants
-----------------------

These constants are used to define the variable type in the
:c:func:`cuOptCreateProblem` and :c:func:`cuOptCreateRangedProblem` functions.

.. doxygendefine:: CUOPT_CONTINUOUS
    :project: cuopt

.. doxygendefine:: CUOPT_INTEGER
    :project: cuopt

Infinity Constant
-----------------

This constant may be used to represent infinity in the
:c:func:`cuOptCreateProblem` and :c:func:`cuOptCreateRangedProblem` functions.

.. doxygendefine:: CUOPT_INFINITY
    :project: cuopt
