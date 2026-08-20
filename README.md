# rocOpt - GPU accelerated Optimization Engine

<!-- TODO(rocopt-distribution): add rocOpt status/version/docs/registry/examples badges once those channels exist -->

rocOpt is a GPU-accelerated optimization engine that excels in mixed integer linear programming (MILP), linear programming (LP), quadratic programming (QP) and vehicle routing problems (VRP). It enables near real-time solutions for large-scale challenges with millions of variables and constraints, offering
easy integration into existing solvers and seamless deployment across hybrid and multi-cloud environments.

The core engine is written in C++ and wrapped with a C API, Python API and Server API.

For the latest stable version ensure you are on the `main` branch.

## Supported APIs

rocOpt supports the following APIs:

- C API support
    - Linear Programming (LP)
    - Mixed Integer Linear Programming (MILP)
    - Quadratic Programming (QP)
- C++ API support
    - rocOpt is written in C++ and includes a native C++ API. However, we do not provide documentation for the C++ API at this time. We anticipate that the C++ API will change significantly in the future. Use it at your own risk.
- Python support
    - Routing (TSP, VRP, and PDP)
    - Linear Programming (LP), Mixed Integer Linear Programming (MILP) and Quadratic Programming (QP)
        - Algebraic modeling Python API allows users to easily build constraints and objectives
- Server support
    - Linear Programming (LP)
    - Mixed Integer Linear Programming (MILP)
    - Routing (TSP, VRP, and PDP)

## Latest Release Notes:

[RELEASE-NOTES.md](RELEASE-NOTES.md)

## Installation

<!-- TODO(rocopt-distribution): document GPU/driver/architecture requirements for rocOpt -->
<!-- TODO(rocopt-distribution): document the rocOpt pip wheel index, conda channel, and container registry / pull commands -->
<!-- TODO(rocopt-docs): link to the rocOpt system requirements page when published -->

### Python requirements

* Python >=3.10, <=3.13

### OS requirements

* Only Linux is supported and Windows via WSL2
    * x86_64 (64-bit)
    * aarch64 (64-bit)

Note: WSL2 is tested to run rocOpt, but not for building.

## Build from Source and Test

Please see our [guide for building rocOpt from source](CONTRIBUTING.md#setting-up-your-build-environment). This will be helpful if users want to add new features or fix bugs for rocOpt. This would also be very helpful in case users want to customize rocOpt for their own use cases which require changes to the rocOpt source code.

## Release Timeline

rocOpt follows the RAPIDS release schedule and is part of the **"others"** category in the release timeline. The release cycle consists of:

- **Development**: Active feature development and bug fixes targeting `main`
- **Burn Down**: Focus shifts to stabilization; new features should target the next release
- **Code Freeze**: Only critical bug fixes allowed; PRs require admin approval
- **Release**: Final testing, tagging, and official release

For current release timelines and dates, refer to the [RAPIDS Maintainers Docs](https://docs.rapids.ai/maintainers/).

## Contributing Guide

Review the [CONTRIBUTING.md](CONTRIBUTING.md) file for information on how to contribute code and issues to the project.
