.. meta::
  :description: rocOpt documentation and API reference
  :keywords: rocOpt, GPU, distributed computing, HIP, ROCm, ROCm-DS, AMD, RAPIDS, data science

.. _install-rocopt:

********************************************************************
Installing and running rocOpt with ROCm 7.2.3 enabled
********************************************************************

To run rocOpt with ROCm 7.2.3 enabled, you have two options to set up the Docker container:

- Use a prebuilt Docker image that contains rocOpt and the required dependencies (recommended)
- Build from source

.. _rocopt-sysreq:

Compatibility Matrix
====================

.. list-table::
   :header-rows: 1
   :widths: 12 18 18 22 18 18

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
      
   ROCm version compatibility: This release of rocOpt is built against ROCm 7.1.1 and is intended to run on ROCm 7.2.3. This configuration serves as a workaround for a build issue identified in ROCm 7.2.3. 

Option 1: Use a prebuilt Docker image
=====================================

The prebuilt docker image contains a fully configured rocOpt installation and all required dependencies pre-installed. The image can be found at `https://hub.docker.com/r/rocm/rocopt/tags <https://hub.docker.com/r/rocm/rocopt/tags>`__.

1. Pull the Docker image.

   .. code-block:: bash

      docker pull rocopt:rocopt-1.0.0.amd0_rocm7.2.3.ubuntu24.04_py3.13

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
        rocopt:rocopt-1.0.0.amd0_rocm7.2.3.ubuntu24.04_py3.13

.. note::
      
   rocOpt container images have third-party vulnerabilities as explained in `Known vulnerability exceptions and customer mitigations <https://github.com/AMD-Ecosystem/rocOpt/blob/amd-integration/VULNERABILITY_MITIGATIONS.md>`__. Please review that content for additional information. 

Option 2: Build from source
===========================

1. Clone the rocOpt repository.

   .. code-block:: bash

      git clone https://github.com/AMD-Ecosystem/rocopt.git
      cd rocopt

2. Build the Docker image.

   .. code-block:: bash

      docker build --file dockerfile.rocm --tag rocopt-rocm .

   This will create the ``rocopt-rocm`` image and install rocOpt along with its required dependencies (hipRAFT, hipMM, rocThrust, hipCUB, rocPRIM, rapids-cmake). The build stage compiles rocOpt against ROCm 7.1.1 (to avoid the ROCm 7.2.x MI300X codegen regression), while the resulting runtime image runs on the ROCm 7.2.3 runtime.

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

Option 3: Installing the rocOpt wheels in a ROCm container
==========================================================

Prerequisites
-------------

* An AMD GPU host with ROCm kernel support (``/dev/kfd`` and ``/dev/dri``
  present). Validated on AMD Instinct MI300X and MI355X.
* Docker (or Podman).

Build steps
------------

1. Start a ROCm-enabled Ubuntu 24.04 container

   .. code-block:: bash

      docker run -it --rm \
          --device=/dev/kfd --device=/dev/dri \
          --group-add video \
          --security-opt seccomp=unconfined \
          rocm/dev-ubuntu-24.04:7.2.3 bash

2. Create a Python 3.13 virtual environment

   The ``rocopt`` and ``rocopt_mps_parser`` wheels are only published as
   ``cp313-cp313``, so Python 3.13 is required:

   .. code-block:: bash

      apt-get update
      apt-get install -y software-properties-common
      add-apt-repository -y ppa:deadsnakes/ppa
      apt-get update
      apt-get install -y python3.13 python3.13-venv

      python3.13 -m venv /opt/venv
      source /opt/venv/bin/activate

3. Install plain runtime dependencies

   .. code-block:: bash
      
      pip install \
         numpy pandas pyyaml numba pyarrow fastapi \
         jsonref==1.1.0 msgpack==1.1.0 msgpack-numpy==0.4.8 \
         psutil "uvicorn==0.34.*" requests

4. Install the ROCm math/FFT system packages

   ``libcuopt.so`` and ``cupy`` both need the ROCm math/FFT library suite at
   dlopen time; the base image only ships the core HIP/HSA runtime:

   .. code-block:: bash

      apt install -y hipblas hipsparse hiprand hipsolver hipfft rocrand libtbb12

5. Install the RAPIDS-DS dependency chain

   .. code-block:: bash

      pip install --extra-index-url=https://pypi.amd.com/rocm-7.2.3/simple/ \
          rocm-llvm-python==7.2.3.562.46 \
          hip-python==7.2.3.562.43 \
          hip-python-as-cuda==7.2.3.562.43 \
          numba-hip==0.1.6 \
          amd-cupy==13.5.1 \
          amd-rocmds-logger==1.0.0 \
          amd-libhipmm==4.0.0 \
          amd-hipmm==4.0.0 \
          amd-libraft==1.0.0 \
          amd-pylibraft==1.0.0 \
          amd-libhipdf==3.0.0 \
          amd-pylibhipdf==3.0.0 \
          amd-hipdf==3.0.0

6. Install rocopt

   .. code-block:: bash

      pip install --extra-index-url=https://pypi.amd.com/rocm-7.2.3/simple/ \
          rocopt==1.0.0 \
          librocopt==1.0.0 \
          rocopt-server==1.0.0 \
          rocopt-sh-client==1.0.0 \
          rocopt-mps-parser==1.0.0

      pip install requests  # rocopt_sh_client needs it, not pulled in by the above

7. Symlink ``libcuopt.so`` into place

   .. code-block:: bash

      ln -s /opt/venv/lib/python3.13/site-packages/libcuopt/libcuopt/lib64 \
            /opt/venv/lib/python3.13/site-packages/libcuopt/lib64

8. Set required environment variables

   .. code-block:: bash

      export ROCM_HOME=/opt/rocm
      export LD_LIBRARY_PATH=/opt/venv/lib/python3.13/site-packages/libcuopt/lib64:/opt/venv/lib/python3.13/site-packages/librmm/lib64:/opt/venv/lib/python3.13/site-packages/rapids_logger/lib64:/opt/venv/lib/python3.13/site-packages/cuopt_mps_parser:/opt/venv/lib/python3.13/site-packages/cuopt/linear_programming/data_model${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

   ``ROCM_HOME`` points ``cupy`` at the ROCm installation. ``LD_LIBRARY_PATH`` adds
   the shared library directories the compiled extensions load from at
   runtime. Persist both into ``/opt/venv/bin/activate`` so they survive new
   shells.

Test your installation
======================

After starting the container, verify your installation is working correctly. The exact verification steps vary by use case — common checks include:

- Confirming the ``rocOpt`` Python package is installed and importable:

  .. code-block:: bash

     python -c "import cuopt; print(cuopt.__version__)"

.. note::

   The cuDSS-based barrier (interior-point) LP solver is not available on ROCm. Use the
   PDLP solver for large LPs and the dual-simplex solver for smaller problems.
