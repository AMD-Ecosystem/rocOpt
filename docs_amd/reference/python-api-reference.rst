.. meta::
   :description: Python API reference for rocopt, covering linear programming, quadratic programming, mixed integer linear programming, and vehicle routing problem classes and functions.
   :keywords: rocopt, Python, API, LP, MILP, QP, VRP, routing, ROCm, optimization, cuopt

====================
Python API reference
====================

This page documents the Python API for rocopt, covering both the ``libcuopt`` Python wrappers (Cython-based) and the ``cuopt`` Python package. The Python API provides access to linear programming (LP), mixed integer linear programming (MILP), quadratic programming (QP) solvers, and vehicle routing problem (VRP) solvers.

For the corresponding C and C++ APIs, see :doc:`/reference/c-api-reference`.

.. note::

   The Python API is built on Cython wrappers that call into the rocopt C++ solver libraries. The internal bridge modules (``cython_solve`` for LP and ``cython`` for routing) are not part of the public API and are not documented here.

Linear programming
******************

The linear programming Python API provides classes and functions for defining and solving LP, MILP, and QP problems. These are exposed through the ``cuopt`` Python package.

.. note::

   The source material available does not contain the full Python-level docstrings, class definitions, or function signatures for the LP Python API. The sections below describe the API surface based on the C++ types that the Python wrappers expose. Consult the installed package help (``help(cuopt)``) or the generated API docs shipped with rocopt for complete Python signatures and parameter details.

Optimization problem
--------------------

The Python wrapper for ``OptimizationProblem`` allows you to define an LP, MILP, or QP optimization problem including the objective function, constraints, and variable bounds.

``OptimizationProblem``
   Represents a complete optimization problem definition. Wraps the C++ ``OptimizationProblem`` class.

   Key attributes and methods include:

   - Setting the objective (linear and optionally quadratic terms)
   - Defining constraint matrices (sparse CSR or CSC format)
   - Setting variable bounds (lower and upper)
   - Specifying variable types (continuous, integer, binary) for MILP problems
   - Setting constraint bounds (right-hand side values and senses)

Solver settings
---------------

``SolverSettings``
   Unified solver settings controlling time limits, tolerances, and algorithm selection for LP, MILP, and QP solvers. Wraps the C++ ``SolverSettings`` class.

   Key parameters include:

   - Time limit for the solve operation
   - Optimality and feasibility tolerances
   - Algorithm selection (PDLP, dual simplex, or branch-and-bound for MIP)
   - Logging verbosity

PDLP solver settings
^^^^^^^^^^^^^^^^^^^^

``PdlpSolverSettings``
   Settings specific to the PDLP (Primal-Dual Hybrid Gradient) GPU-accelerated LP solver.

   Key parameters include:

   - Primal and dual feasibility tolerances
   - Optimality gap tolerance
   - Maximum iteration count

``PdlpHyperParams``
   Hyper-parameters for fine-tuning the PDLP solver behavior.

``PdlpWarmStartData``
   Container for warm-start data that can be passed to the PDLP solver to accelerate convergence when solving related problems sequentially.

MIP solver settings
^^^^^^^^^^^^^^^^^^^

``MipSolverSettings``
   Settings for the mixed integer programming branch-and-bound solver.

   Key parameters include:

   - MIP gap tolerance (relative and absolute)
   - Node limit
   - Heuristic strategies

``MipSolverSolution``
   Container for the MIP solver solution, including the objective value, variable values, and solve status.

``MipSolverStats``
   Statistics from the MIP solve, including node count, number of cuts, and timing information.

Solve function
--------------

``solve``
   Top-level function that dispatches an LP, MILP, or QP problem to the appropriate internal solver based on the problem type and solver settings.

   .. code-block:: python

      from cuopt.linear_programming import solve

      solution = solve(problem, settings)

   :param problem: An ``OptimizationProblem`` instance defining the optimization problem.
   :param settings: A ``SolverSettings`` instance controlling solver behavior.
   :returns: A solution object containing the optimal variable values, objective value, and solver status.

PDLP solution
^^^^^^^^^^^^^

``PdlpSolverSolution``
   Container for the PDLP solver solution, including primal and dual variable values, objective value, and convergence information.

MPS parser
----------

The ``cuopt_mps_parser`` Python package provides an interface for reading and writing MPS-format problem files.

``MpsParser``
   Parses MPS and MIPLIB format files into a data model that can be passed to the solver.

``MpsDataModel``
   Holds the parsed problem data from an MPS file.

``MpsDataModelView``
   Read-only view of the parsed MPS data model.

``MpsWriter``
   Writes an optimization problem back to MPS format.

Vehicle routing
***************

The vehicle routing Python API provides classes for defining and solving vehicle routing problems, including TSP, VRP, and pickup-and-delivery problems. These classes wrap the C++ routing API through Cython bindings.

For a complete walkthrough, see :doc:`../examples/rocopt-examples`.

DataModelView
-------------

``DataModelView``
   Defines the data model for a vehicle routing problem, including locations, demands, time windows, vehicle capacities, and fleet information. This is the primary input class for the routing solver.

   Key attributes and methods include:

   - Setting the number of locations and vehicles
   - Defining cost and time matrices
   - Setting task demands and vehicle capacities
   - Configuring time windows for tasks and vehicles
   - Setting pickup-and-delivery pairs
   - Defining precedence constraints
   - Specifying vehicle start and end locations

WaypointMatrix
--------------

``WaypointMatrix``
   Computes distance and travel-time matrices from waypoint graph data. Use this class when you have a road network or graph representation rather than precomputed matrices.

   Key functionality:

   - Accepts waypoint coordinates and graph edges
   - Computes shortest-path cost and time matrices
   - Can be used to populate the matrices in ``DataModelView``

SolverSettings (routing)
------------------------

``SolverSettings``
   Controls the behavior of the vehicle routing solver, including time limits and solution quality parameters.

   Key parameters include:

   - Time limit for the optimization
   - Number of climbers (parallel search threads on the GPU)
   - Solution strategy selection

   .. code-block:: python

      from cuopt.routing import SolverSettings

      settings = SolverSettings()
      settings.set_time_limit(10.0)

Assignment
----------

``Assignment``
   Represents the solution to a vehicle routing problem. Contains the route assignments for each vehicle.

   Key methods include:

   - Retrieving the routes for each vehicle
   - Getting the total cost of the solution
   - Checking solution feasibility
   - Accessing per-vehicle metrics (distance, time, load)

Routing solve function
----------------------

``solve``
   Solves a vehicle routing problem given a data model and solver settings.

   .. code-block:: python

      from cuopt.routing import solve

      assignment = solve(data_model, settings)

   :param data_model: A ``DataModelView`` instance defining the routing problem.
   :param settings: A ``SolverSettings`` instance controlling solver behavior.
   :returns: An ``Assignment`` instance containing the optimized vehicle routes.

Constants and status codes
**************************

The Python API exposes the same status codes and constants defined in the C API. These include solver termination statuses (optimal, infeasible, time limit reached, and others) and special values such as infinity bounds.

For details on the underlying constants, see :doc:`/reference/c-api-reference`.

Error handling
**************

Python API calls raise exceptions when errors occur. The exception types map to the underlying ``cuoptError_t`` error codes from the C++ library. Common error conditions include:

- Invalid problem dimensions or data
- Incompatible solver settings
- GPU memory allocation failures
- Solver convergence failures
