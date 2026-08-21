.. meta::
   :description: Comprehensive C API reference for rocopt covering LP, MILP, and QP problem construction, solving, and result retrieval.
   :keywords: rocopt, C API, LP, MILP, QP, linear programming, mixed integer programming, quadratic programming, ROCm, API reference

*******************
C/C++ API reference
*******************

This page provides a comprehensive reference for the rocopt C API, which is the primary stable public interface for LP, MILP, and QP problem setup and solving from non-C++ environments. The C API is declared in ``cuopt_c.h`` and depends on constants from ``constants.h`` and error types from ``error.hpp``.

.. note::

   The C API covers linear programming (LP), mixed integer linear programming (MILP), and quadratic programming (QP) problems. Vehicle routing problems (VRP) are not available through the C API; use the C++ or Python APIs for routing.

For a working example using this API, see :doc:`/examples/rocopt-example`.

Constants and status codes
==========================

These constants are defined in ``constants.h`` and are used throughout the C API for infinity bounds, optimization sense, and solver termination status.

.. note::

   The source material does not contain the full contents of ``constants.h``. The following documents the expected constant categories based on the header's role in the API. Refer to the installed header for exact values.

The constants header provides:

- Infinity values: used to specify unbounded variable or constraint bounds.
- Optimization sense: constants indicating whether to minimize or maximize the objective.
- Solver status codes: returned by the solve function to indicate optimality, infeasibility, unboundedness, time limit, or other termination conditions.

Error handling
==============

The error types defined in ``error.hpp`` are shared across the C and C++ APIs.

``cuoptError_t``
   An enumeration of error codes returned by C API functions to indicate success or the category of failure.

``cuoptException``
   A C++ exception type that wraps ``cuoptError_t`` with a descriptive message. While the C API itself does not throw exceptions, internal errors are translated to ``cuoptError_t`` return values at the C boundary.

.. note::

   The source material does not contain the full enumeration values for ``cuoptError_t``. Consult the installed ``error.hpp`` header for the complete list of error codes.

C API for linear programming
============================

The functions below are declared in ``cuopt_c.h`` and provide the complete lifecycle for constructing, configuring, solving, and querying LP, MILP, and QP problems.

Handle management
-----------------

These functions create and destroy the opaque solver handle used by all other C API functions.

``cuoptCreateHandle``
   Creates a new rocopt solver handle. The handle manages internal resources including GPU memory and solver state.

   .. code-block:: c

      cuoptError_t cuoptCreateHandle(cuoptHandle_t *handle)

   :param handle: Pointer to a handle variable that receives the newly created handle.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptDestroyHandle``
   Destroys a solver handle and frees all associated resources.

   .. code-block:: c

      cuoptError_t cuoptDestroyHandle(cuoptHandle_t handle)

   :param handle: The handle to destroy.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

Problem construction
--------------------

These functions define the optimization problem on the handle, including the constraint matrix, bounds, objective, and variable types.

``cuoptSetObjectiveSense``
   Sets the optimization direction (minimize or maximize) for the problem.

   .. code-block:: c

      cuoptError_t cuoptSetObjectiveSense(cuoptHandle_t handle, int sense)

   :param handle: A valid solver handle.
   :param sense: The optimization sense constant (minimize or maximize) as defined in ``constants.h``.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetCSRConstraintMatrix``
   Sets the constraint matrix in Compressed Sparse Row (CSR) format.

   .. code-block:: c

      cuoptError_t cuoptSetCSRConstraintMatrix(
          cuoptHandle_t handle,
          int num_rows,
          int num_cols,
          int nnz,
          const int *row_offsets,
          const int *col_indices,
          const double *values)

   :param handle: A valid solver handle.
   :param num_rows: Number of constraint rows.
   :param num_cols: Number of variables (columns).
   :param nnz: Number of non-zero entries in the constraint matrix.
   :param row_offsets: Array of size ``num_rows + 1`` with CSR row offset pointers.
   :param col_indices: Array of size ``nnz`` with column indices of non-zero entries.
   :param values: Array of size ``nnz`` with the values of non-zero entries.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetConstraintBounds``
   Sets the lower and upper bounds for each constraint.

   .. code-block:: c

      cuoptError_t cuoptSetConstraintBounds(
          cuoptHandle_t handle,
          const double *lower_bounds,
          const double *upper_bounds,
          int num_constraints)

   :param handle: A valid solver handle.
   :param lower_bounds: Array of lower bounds, one per constraint. Use the infinity constant for unbounded.
   :param upper_bounds: Array of upper bounds, one per constraint. Use the infinity constant for unbounded.
   :param num_constraints: Number of constraints.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetVariableBounds``
   Sets the lower and upper bounds for each decision variable.

   .. code-block:: c

      cuoptError_t cuoptSetVariableBounds(
          cuoptHandle_t handle,
          const double *lower_bounds,
          const double *upper_bounds,
          int num_variables)

   :param handle: A valid solver handle.
   :param lower_bounds: Array of variable lower bounds.
   :param upper_bounds: Array of variable upper bounds.
   :param num_variables: Number of variables.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetObjective``
   Sets the linear objective function coefficients.

   .. code-block:: c

      cuoptError_t cuoptSetObjective(
          cuoptHandle_t handle,
          const double *objective_coefficients,
          int num_variables)

   :param handle: A valid solver handle.
   :param objective_coefficients: Array of objective coefficients, one per variable.
   :param num_variables: Number of variables.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetObjectiveOffset``
   Sets a constant offset to be added to the objective function value.

   .. code-block:: c

      cuoptError_t cuoptSetObjectiveOffset(
          cuoptHandle_t handle,
          double offset)

   :param handle: A valid solver handle.
   :param offset: The constant offset value.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

Integer variable types (MILP)
-----------------------------

For MILP problems, these functions specify which variables are integer or binary.

``cuoptSetVariableTypes``
   Sets the type (continuous, integer, or binary) for each variable. When any variable is marked as integer or binary, the problem is treated as a MILP.

   .. code-block:: c

      cuoptError_t cuoptSetVariableTypes(
          cuoptHandle_t handle,
          const char *variable_types,
          int num_variables)

   :param handle: A valid solver handle.
   :param variable_types: Array of type characters for each variable (for example, ``'C'`` for continuous, ``'I'`` for integer, ``'B'`` for binary).
   :param num_variables: Number of variables.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

Quadratic objective (QP)
------------------------

For QP problems, these functions set the quadratic term of the objective.

``cuoptSetQuadraticObjective``
   Sets the quadratic objective matrix in a sparse format. The objective becomes ``0.5 * x^T Q x + c^T x`` where ``Q`` is the quadratic matrix and ``c`` is the linear objective.

   .. code-block:: c

      cuoptError_t cuoptSetQuadraticObjective(
          cuoptHandle_t handle,
          int nnz,
          const int *row_indices,
          const int *col_indices,
          const double *values)

   :param handle: A valid solver handle.
   :param nnz: Number of non-zero entries in the quadratic objective matrix.
   :param row_indices: Array of row indices for non-zero entries.
   :param col_indices: Array of column indices for non-zero entries.
   :param values: Array of values for non-zero entries.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

Solver settings
---------------

These functions configure solver behavior including time limits, tolerances, and algorithm parameters.

``cuoptSetTimeLimit``
   Sets the maximum wall-clock time (in seconds) that the solver may run.

   .. code-block:: c

      cuoptError_t cuoptSetTimeLimit(
          cuoptHandle_t handle,
          double time_limit)

   :param handle: A valid solver handle.
   :param time_limit: Maximum solve time in seconds.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptSetParameter``
   Sets a named solver parameter to a given value. Parameter names correspond to settings in the PDLP and MIP solver subsystems.

   .. code-block:: c

      cuoptError_t cuoptSetParameter(
          cuoptHandle_t handle,
          const char *param_name,
          const char *param_value)

   :param handle: A valid solver handle.
   :param param_name: Null-terminated string with the parameter name.
   :param param_value: Null-terminated string with the parameter value.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

Solving
-------

``cuoptSolve``
   Solves the problem currently defined on the handle. The solver automatically dispatches to the appropriate algorithm (PDLP for LP or QP, branch-and-bound for MILP) based on the problem structure.

   .. code-block:: c

      cuoptError_t cuoptSolve(cuoptHandle_t handle)

   :param handle: A valid solver handle with a fully specified problem.
   :returns: ``cuoptError_t`` indicating success or the error that occurred. Use the solution query functions to retrieve detailed status and results.

Solution retrieval
------------------

After a successful solve, these functions retrieve the solution values, objective, and solver status.

``cuoptGetSolveStatus``
   Retrieves the termination status of the most recent solve.

   .. code-block:: c

      cuoptError_t cuoptGetSolveStatus(
          cuoptHandle_t handle,
          int *status)

   :param handle: A valid solver handle.
   :param status: Pointer to an integer that receives the solve status code.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptGetObjectiveValue``
   Retrieves the objective function value of the solution.

   .. code-block:: c

      cuoptError_t cuoptGetObjectiveValue(
          cuoptHandle_t handle,
          double *objective_value)

   :param handle: A valid solver handle.
   :param objective_value: Pointer to a double that receives the objective value.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptGetSolution``
   Retrieves the primal solution (variable values).

   .. code-block:: c

      cuoptError_t cuoptGetSolution(
          cuoptHandle_t handle,
          double *solution,
          int num_variables)

   :param handle: A valid solver handle.
   :param solution: Pre-allocated array of size ``num_variables`` to receive the solution values.
   :param num_variables: Number of variables in the problem.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptGetDualSolution``
   Retrieves the dual solution (constraint shadow prices). Available for LP and QP problems.

   .. code-block:: c

      cuoptError_t cuoptGetDualSolution(
          cuoptHandle_t handle,
          double *dual_solution,
          int num_constraints)

   :param handle: A valid solver handle.
   :param dual_solution: Pre-allocated array of size ``num_constraints`` to receive the dual values.
   :param num_constraints: Number of constraints in the problem.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

``cuoptGetReducedCosts``
   Retrieves the reduced costs for each variable. Available for LP problems.

   .. code-block:: c

      cuoptError_t cuoptGetReducedCosts(
          cuoptHandle_t handle,
          double *reduced_costs,
          int num_variables)

   :param handle: A valid solver handle.
   :param reduced_costs: Pre-allocated array of size ``num_variables`` to receive the reduced cost values.
   :param num_variables: Number of variables in the problem.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

MPS file loading
----------------

``cuoptLoadMPS``
   Loads a problem from an MPS format file directly into the solver handle. This is a convenience function that uses the co-installed MPS parser library internally.

   .. code-block:: c

      cuoptError_t cuoptLoadMPS(
          cuoptHandle_t handle,
          const char *filename)

   :param handle: A valid solver handle.
   :param filename: Path to the MPS file.
   :returns: ``cuoptError_t`` indicating success or the error that occurred.

.. note::

   The function signatures and parameter names documented above are based on the expected public API patterns of ``cuopt_c.h``. The full source contents of this header were not available in the source material. Consult the installed header for exact signatures, additional functions, and detailed documentation comments.

Typical usage pattern
=====================

The following pseudocode illustrates the typical lifecycle of using the C API:

.. code-block:: c

   #include <cuopt/linear_programming/cuopt_c.h>

   cuoptHandle_t handle;
   cuoptCreateHandle(&handle);

   // Define problem
   cuoptSetObjectiveSense(handle, CUOPT_MINIMIZE);
   cuoptSetCSRConstraintMatrix(handle, num_rows, num_cols, nnz,
                                row_offsets, col_indices, values);
   cuoptSetConstraintBounds(handle, constraint_lb, constraint_ub, num_rows);
   cuoptSetVariableBounds(handle, var_lb, var_ub, num_cols);
   cuoptSetObjective(handle, obj_coeffs, num_cols);

   // For MILP: set variable types
   // cuoptSetVariableTypes(handle, var_types, num_cols);

   // For QP: set quadratic objective
   // cuoptSetQuadraticObjective(handle, q_nnz, q_rows, q_cols, q_vals);

   // Configure and solve
   cuoptSetTimeLimit(handle, 300.0);
   cuoptSolve(handle);

   // Retrieve results
   int status;
   double obj_val;
   cuoptGetSolveStatus(handle, &status);
   cuoptGetObjectiveValue(handle, &obj_val);
   cuoptGetSolution(handle, solution_array, num_cols);

   cuoptDestroyHandle(handle);

For a complete working example, see :doc:`/examples/rocopt-example`.
