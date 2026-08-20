.. meta::
   :description: Server API reference for rocopt, documenting REST endpoints for VRP and LP/MILP problem submission, status polling, warm start, initial solution upload, and deletion.
   :keywords: rocopt, server API, REST API, VRP, LP, MILP, cuopt-server, endpoints, ROCm

====================
Server API reference
====================

This page documents the REST API exposed by the rocopt server (cuopt-server). The server wraps the rocopt optimization engine and provides HTTP endpoints for submitting vehicle routing problems (VRP) and linear or mixed-integer linear programming (LP/MILP) problems, polling for results, managing cached requests, and supplying warm-start or initial solution data.

.. note::

   The source material available does not contain complete OpenAPI or Swagger specifications for every endpoint, nor full JSON schema definitions for all request and response bodies. The reference below is constructed from the server source code, test files, and client library source that were available. Some details may require supplementation from the deployed server's ``/docs`` (Swagger UI) endpoint.

General conventions
*******************

- The server is a FastAPI application and exposes interactive documentation at ``/docs`` (Swagger UI) and ``/redoc`` when running.
- All request and response bodies use JSON (``Content-Type: application/json``).
- Endpoints that accept optimization problems return a request ID that you use to poll for status and retrieve results.
- The server listens on a configurable host and port (default ``0.0.0.0:5000``).

Health and version
******************

``GET /health``
---------------

Returns the health status of the server.

.. code-block:: text

   GET /health

**Response (200)**

.. code-block:: json

   {
     "health": "OK"
   }

``GET /version``
----------------

Returns the version of the rocopt server and solver engine.

.. code-block:: text

   GET /version

**Response (200)**

.. code-block:: json

   {
     "version": "<server-version-string>"
   }

VRP endpoints
*************

These endpoints handle vehicle routing problem submission and result retrieval.

``POST /cuopt/request``
-----------------------

Submit a VRP problem for solving. The request body contains the full problem specification including the cost matrix or waypoint data, fleet information, task data, and solver settings.

.. code-block:: text

   POST /cuopt/request

**Request body**

A JSON object describing the VRP problem. Key top-level fields include:

.. list-table::
   :header-rows: 1
   :widths: 25 15 60

   * - Field
     - Type
     - Description
   * - ``cost_matrix_data``
     - object
     - Cost or distance matrix data for the problem. May contain ``cost_matrix`` (a 2-D array) or reference a previously uploaded matrix.
   * - ``travel_time_matrix_data``
     - object
     - Travel time matrix data, structured similarly to ``cost_matrix_data``.
   * - ``fleet_data``
     - object
     - Fleet information including vehicle capacities, time windows, start and end locations, and vehicle IDs.
   * - ``task_data``
     - object
     - Task (order) information including locations, demands, time windows, service times, pickup and delivery pairs, and priorities.
   * - ``solver_config``
     - object
     - Solver configuration including time limit, number of climbers (parallel search threads), and solution strategy.

**Response (200)**

.. code-block:: json

   {
     "reqId": "<unique-request-id>"
   }

``GET /cuopt/request/{req_id}``
-------------------------------

Poll for the status and results of a previously submitted VRP request.

.. code-block:: text

   GET /cuopt/request/{req_id}

:param req_id: The unique request ID returned by the ``POST /cuopt/request`` endpoint.

**Response (200) — completed**

.. code-block:: json

   {
     "reqId": "<request-id>",
     "status": "completed",
     "response": {
       "solver_response": {
         "status": 0,
         "num_vehicles": 3,
         "solution_cost": 1234.5,
         "vehicle_data": {
           "<vehicle_id>": {
             "task_id": ["task_0", "task_1"],
             "arrival_stamp": [0.0, 10.5],
             "route": [0, 3, 7],
             "type": ["Depot", "Delivery", "Depot"]
           }
         }
       }
     }
   }

**Response (200) — pending**

.. code-block:: json

   {
     "reqId": "<request-id>",
     "status": "pending"
   }

``DELETE /cuopt/request/{req_id}``
----------------------------------

Delete a cached VRP request and its results.

.. code-block:: text

   DELETE /cuopt/request/{req_id}

:param req_id: The request ID to delete.

**Response (200)**

.. code-block:: json

   {
     "reqId": "<request-id>",
     "status": "deleted"
   }

LP/MILP endpoints
*****************

These endpoints handle linear programming and mixed-integer linear programming problem submission and result retrieval.

``POST /cuopt/lp``
------------------

Submit an LP or MILP problem for solving. The request body contains the problem data in a JSON representation.

.. code-block:: text

   POST /cuopt/lp

**Request body**

A JSON object describing the LP/MILP problem. Key fields include:

.. list-table::
   :header-rows: 1
   :widths: 25 15 60

   * - Field
     - Type
     - Description
   * - ``csr_constraint_matrix``
     - object
     - Constraint matrix in compressed sparse row (CSR) format with ``offsets``, ``indices``, and ``values`` arrays.
   * - ``constraint_bounds``
     - object
     - Contains ``upper_bounds`` and ``lower_bounds`` arrays for constraints.
   * - ``objective``
     - object
     - Objective function coefficients (``coefficients`` array), optimization ``sense`` (``"minimize"`` or ``"maximize"``), and optional ``offset``.
   * - ``variable_bounds``
     - object
     - Contains ``upper_bounds`` and ``lower_bounds`` arrays for decision variables.
   * - ``variable_names``
     - array
     - Optional list of variable names.
   * - ``variable_types``
     - array
     - Array of variable types (e.g., ``"C"`` for continuous, ``"I"`` for integer, ``"B"`` for binary). Presence of integer or binary types makes this an MILP problem.
   * - ``solver_config``
     - object
     - Solver settings such as time limit and tolerances.

**Response (200)**

.. code-block:: json

   {
     "reqId": "<unique-request-id>"
   }

``GET /cuopt/lp/{req_id}``
--------------------------

Poll for the status and results of a previously submitted LP/MILP request.

.. code-block:: text

   GET /cuopt/lp/{req_id}

:param req_id: The unique request ID returned by ``POST /cuopt/lp``.

**Response (200) — completed**

.. code-block:: json

   {
     "reqId": "<request-id>",
     "status": "completed",
     "response": {
       "solver_response": {
         "status": "Optimal",
         "objective_value": 42.0,
         "primal_solution": [1.0, 0.0, 3.5],
         "dual_solution": [0.5, -1.0]
       }
     }
   }

``DELETE /cuopt/lp/{req_id}``
-----------------------------

Delete a cached LP/MILP request and its results.

.. code-block:: text

   DELETE /cuopt/lp/{req_id}

:param req_id: The request ID to delete.

**Response (200)**

.. code-block:: json

   {
     "reqId": "<request-id>",
     "status": "deleted"
   }

Request caching
***************

The server caches submitted problem data so that repeated submissions with the same data can avoid re-uploading. Certain data components (such as cost matrices) can be uploaded independently and referenced by ID in subsequent requests.

``PUT /cuopt/data``
-------------------

Upload reusable data (such as a cost matrix) that can be referenced in subsequent VRP requests.

.. code-block:: text

   PUT /cuopt/data

**Request body**

A JSON object containing the data to cache. The exact schema depends on the data type being uploaded (for example, ``cost_matrix_data`` or ``travel_time_matrix_data``).

**Response (200)**

.. code-block:: json

   {
     "dataId": "<data-identifier>"
   }

``DELETE /cuopt/data/{data_id}``
--------------------------------

Delete previously cached data.

.. code-block:: text

   DELETE /cuopt/data/{data_id}

:param data_id: The identifier for the cached data.

**Response (200)**

.. code-block:: json

   {
     "dataId": "<data-identifier>",
     "status": "deleted"
   }

Warm start
**********

For LP problems, you can supply warm-start data to accelerate solving by providing primal and dual solution vectors from a prior solve.

To use warm start, include a ``warm_start`` field in the ``solver_config`` object of your ``POST /cuopt/lp`` request:

.. code-block:: json

   {
     "solver_config": {
       "warm_start": {
         "primal_solution": [1.0, 0.0, 3.5],
         "dual_solution": [0.5, -1.0]
       }
     }
   }

Initial solution upload (VRP)
*****************************

For VRP problems, you can supply an initial solution to guide the solver. Include an ``initial_solution`` field in your ``POST /cuopt/request`` body:

.. code-block:: json

   {
     "solver_config": {
       "initial_solution": {
         "vehicle_data": {
           "vehicle_0": {
             "task_id": ["task_0", "task_1"],
             "route": [0, 3, 7]
           }
         }
       }
     }
   }

The solver uses this as a starting point and attempts to improve upon it within the configured time limit.

Error responses
***************

When the server encounters an error, it returns a JSON response with an error message:

.. code-block:: json

   {
     "error": "<error-description>",
     "status": "error"
   }

Common HTTP status codes:

.. list-table::
   :header-rows: 1
   :widths: 15 85

   * - Code
     - Description
   * - ``200``
     - Request accepted or results returned successfully.
   * - ``400``
     - Malformed request body or invalid problem data.
   * - ``404``
     - Request ID or data ID not found.
   * - ``500``
     - Internal server error during problem solving.
