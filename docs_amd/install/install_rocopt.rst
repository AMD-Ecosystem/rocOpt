.. meta::
  :description: rocOpt documentation and API reference
  :keywords: rocOpt, GPU, distributed computing, HIP, ROCm, ROCm-DS, AMD, RAPIDS, data science

.. _install-rocopt:

********************************************************************
Run rocOpt with ROCm 7.2.3 enabled
********************************************************************

To run rocOpt with ROCm 7.2.3 enabled, you have two options to set up the Docker container:

- Use a prebuilt Docker image that contains rocOpt and the required dependencies (recommended)
- Build from source

.. _rocopt-sysreq:

Compatibility Matrix
====================

.. list-table::
   :header-rows: 1
   :widths: 12 18 18 22 18

   * - rocOpt version
     - Ubuntu
     - ROCm version (build → runtime)
     - Python version
     - PyTorch version
     - AMD Instinct GPU
   * - 1.0.0
     - 24.04
     - 7.1.1 (build) → 7.2.3 (runtime)
     - 3.13
     - N/A
     - MI300X, MI355X
        
.. note::
      
   ROCm version compatibility: This release of rocOpt is built against ROCm 7.1.1 and is intended to run on ROCm 7.2.3. This configuration serves as a workaround for a build issue identified in ROCm 7.2.3. The issue has been fixed for future releases. 

Option 1: Use a prebuilt Docker image
=====================================

The prebuilt image contains a fully configured rocOpt installation and all required dependencies pre-installed.

1. Pull the Docker image.

   .. code-block:: bash

      docker pull rocopt:rocopt-1.0.0.amd0_rocm7.2.3_ubuntu24.04

2. Start a Docker container using this image.

   .. code-block:: bash

      docker run -it --privileged \
        --rm \
        --device=/dev/kfd \
        --device=/dev/dri \
        --group-add video \
        --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --ipc=host \
        rocopt:rocopt-1.0.0.amd0_rocm7.2.3_ubuntu24.04

Option 2: Build from source
===========================

1. Clone the rocOpt repository.

   .. code-block:: bash

      git clone https://github.com/AMD-Ecosystem/rocopt.git
      cd rocopt

2. Build the Docker image.

   .. code-block:: bash

      docker build --file dockerfile.rocm --tag rocopt-rocm .

   This will pull the ``rocopt-1.0.0.amd0_rocm7.2.3_ubuntu24.04`` image and install rocOpt along with its required dependencies (hipRAFT, hipMM, rocThrust, hipCUB, rocPRIM, rapids-cmake). The build stage compiles rocOpt against ROCm 7.1.1 (to avoid the ROCm 7.2.x MI300X codegen regression), while the resulting runtime image runs on the ROCm 7.2.3 runtime.

3. Launch a container based on the image.

   .. code-block:: bash

      docker run -it --privileged \
        --rm \
        --device=/dev/kfd \
        --device=/dev/dri \
        --group-add video \
        --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --ipc=host \
        rocopt-rocm

4. Inside the container, build the rocOpt C++ library.

   .. code-block:: bash

      USE_ROCM=1 ./build.sh

Test your installation
======================

After starting the container, verify your installation is working correctly. The exact verification steps vary by use case — common checks include:

- Confirming the rocOpt Python package is installed and importable:

  .. code-block:: bash

     python -c "import cuopt; print(cuopt.__version__)"

.. note::

   The cuDSS-based barrier (interior-point) LP solver is not available on ROCm. Use the
   PDLP solver for large LPs and the dual-simplex solver for smaller problems.
