.. meta::
  :description: rocOpt documentation and API reference
  :keywords: rocOpt, GPU, distributed computing, HIP, ROCm, ROCm-DS, AMD, RAPIDS, data science

.. _whatis-rocopt:

********************************************************************
What is rocOpt?
********************************************************************

rocOpt is an open-source, GPU-accelerated engine for decision optimization on AMD Instinct
GPUs through the ROCm software stack. It solves large-scale linear programming (LP),
mixed-integer linear programming (MILP), quadratic programming (QP), and vehicle routing
problems containing millions of variables and constraints, returning near real-time results on
AMD Instinct MI300X and MI355X GPUs through the ROCm software stack.

rocOpt is aligned with and API-compatible with NVIDIA cuOpt 25.10, so you can run
existing cuOpt workloads and optimization pipelines on AMD Instinct GPUs without
rewriting client code.

By moving the heavy linear algebra onto the GPU, rocOpt accelerates
decision-making in operations research, logistics, supply chain, and scheduling
workloads — domains where traditional CPU-only solvers often struggle to deliver
answers within useful time budgets.

The current release is rocOpt 1.0.0, which is compiled against ROCm 7.1.1 and runs on
the ROCm 7.2.3 runtime. This includes the following features:

- rocOpt offers solver families tuned for the main mathematical programming problem
  classes. Each solver targets a different balance of problem size, structure, and
  solution quality:

  - PDLP (Primal-Dual Hybrid Gradient) — GPU first-order method for very large,
    sparse LPs; recommended for million-variable problems on rocOpt.
  - Dual simplex — CPU-based method for small-to-medium LPs; also drives LP
    relaxations inside the MILP branch-and-bound loop.
  - MILP — hybrid GPU/CPU mixed-integer solver combining GPU primal heuristics with
    CPU branch-and-bound.
  - QP — quadratic programming for objectives such as portfolio risk/return trade-offs.
  - Vehicle routing (TSP / VRP / PDP) — metaheuristic routing that improves routes
    within a user-specified time budget.

- rocOpt includes APIs and tooling to build, run, and deploy optimization workflows:

  - Python API — construct models, configure solvers, and run solves from Python
    (``import cuopt`` for API compatibility with upstream).
  - CLI — solve problems from standard MPS/LP inputs on the command line.
  - Server API — serve optimization requests over HTTP with a cuOpt-compatible
    interface.

- rocOpt is built on the ROCm Data Science (ROCm-DS) stack — a HIP port of NVIDIA's
  cuOpt that maps RAPIDS-style dependencies to their ROCm equivalents (hipRAFT, hipMM,
  rocThrust, hipCUB, rocPRIM, hipSPARSE, hipBLAS, hipSOLVER) so workloads run on
  AMD Instinct hardware alongside other ROCm-DS libraries such as hipDF.

- rocOpt supports concrete decision-optimization use cases where GPU acceleration
  changes what is tractable in production, including:

  - Last-mile logistics and fleet routing (VRP) with time windows and capacity constraints.
  - Energy dispatch and unit commitment (MILP) with short market intervals.
  - Portfolio optimization (QP) over thousands of instruments.
  - Supply chain network design (MILP) across multi-echelon networks.

.. note::

   The Barrier (interior-point) LP solver depends on the NVIDIA cuDSS sparse direct
   solver, and has no ROCm equivalent in this release. Use PDLP for large LPs and
   dual simplex for smaller problems.
