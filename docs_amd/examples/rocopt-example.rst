.. meta::
  :description: rocOpt documentation and API reference
  :keywords: rocOpt, GPU, distributed computing, HIP, ROCm, ROCm-DS, AMD, RAPIDS, data science

.. _rocopt-example:

********************************************************************
rocOpt examples
********************************************************************

The rocOpt examples can be found in GitHub under the https://github.com/AMD-Ecosystem/rocopt/tree/amd-integration/examples_notebook folder.
The examples include the following three notebooks to demonstrate vehicle routing problems, large-scale linear programming, and mixed-integer
linear programming. 

Example notebooks
====================

The available notebooks and the problems they solve are listed in the following table. 

.. list-table::
   :header-rows: 1
   :widths: 30 25 18 9 18

   * - Notebook
     - Problem
     - Dataset
     - Solve time
     - Notes
   * - ``last_mile_delivery/cvrptw_benchmark_rocopt.ipynb``
     - Routing: capacitated VRP with time windows, 1000 customers
     - ``C1_10_1.TXT`` from the Gehring & Homberger benchmark
     - ~60 s
     - GPU check uses ``rocm-smi``; reads ``/tmp/data/C1_10_1.TXT``
   * - ``diet_optimization/diet_optimization_lp.ipynb``
     - LP: USDA diet (algebraic-modeling API)
     - none
     - < 1 s
     - GPU check uses ``amd-smi``; PDLP-only (``method=1``)
   * - ``diet_optimization/diet_optimization_milp.ipynb``
     - MILP: same diet with integer servings
     - none
     - seconds
     - Same patches as the LP notebook

Vehicle routing problem notebook (``cvrptw_benchmark_rocopt.ipynb``)
--------------------------------------------------------------------

A 1000-customer Gehring & Homberger CVRPTW instance (``C1_10_1``, best known
cost 42 478.95 with 100 vehicles). Restart the kernel and run all cells.
The single solve is capped at 60 s for demo runtime; the upstream NVIDIA
notebook chains a 10 s + 120 s pair.

Run-to-run variance of a few percent is expected. cuOpt's routing solver is
a randomized parallel local-search metaheuristic; identical inputs do not
produce bit-identical outputs across GPU runs.

Diet optimization notebook (``diet_optimization_lp.ipynb`` and ``..._milp.ipynb``)
-----------------------------------------------------------------------------------

Solve the classic USDA diet LP (and an MILP variant with integer servings)
through the algebraic-modeling Python API.

The solver method is pinned to **PDLP only** (``method=1``) on rocopt. The
default ``method=0`` (Concurrent) launches a Barrier solver thread alongside
PDLP, but Barrier requires cuDSS, which is NVIDIA-only. On rocopt the missing
dispatcher path can deadlock a re-solve of the same ``Problem`` object — most
visibly in the MILP notebook, which solves the LP relaxation twice.

Prerequisites
=============

As described in :ref:`install-rocopt`, the rocOpt component requires the following:

- Linux host with an AMD Instinct MI300X (``gfx942``) or MI355X (``gfx950``) GPU.
- ROCm 7.2.3 runtime and Docker with ``/dev/kfd`` + ``/dev/dri`` access for the
  running user (typically via the ``video`` group). rocOpt 1.0.0 is built
  against ROCm 7.1.1 and runs on the ROCm 7.2.3 runtime.
- A rocopt container image. Either:

  - **Pull the prebuilt image** from the published Dockerfile (link TBD), or
  - **Build from source** in this repo:

    .. code-block:: bash

       cd ~/rocopt-working
       export GH_USERNAME=<your-github-username>    # repo is private
       export GH_TOKEN=<your-PAT>
       ./scripts/build-image.sh                      # tags rocopt:amd-integration

    Default branch is ``amd-integration``, which contains these notebooks. To
    pin a different branch pass ``--branch <name>``.

Quick start (in-image clone, no host mount)
===========================================

.. note::

   These steps are for the **prebuilt rocopt container image pulled from the
   registry** (the online image). They fetch the example notebooks, Jupyter,
   and the dataset at runtime because the published image does not include
   them. If you instead build the image from source, these components may
   already be present, and you can skip the corresponding steps.

This is the typical path for new users: 

- Pull the prebuilt docker image and get a shell
- Install the prerequisites: the example notebooks, ``git`` (optional), and Jupyter
- Fetch the dataset for the vehicle routing notebook
- Launch Jupyter notebook

1. Run the container
--------------------

Pull and run the prebuilt image from the registry:

.. code-block:: bash

   docker run -it --rm \
     --name rocopt-jup \
     --device=/dev/kfd --device=/dev/dri \
     --group-add video --ipc=host \
     --shm-size 16G --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
     -p 8888:8888 \
     rocopt:amd-integration

The working directory is ``/rocopt-release`` with the ``cuopt_dev`` conda env
auto-activated.

2. Install prerequisites (notebooks, git, and Jupyter)
------------------------------------------------------

The prebuilt image is intentionally minimal, so set it up for the examples by
fetching the notebooks and installing Jupyter. If you built the image from
source these components may already be present, so skip whatever you already
have.

**Fetch the example notebooks.** The docker image does not include the example
notebooks, so fetch them from the repo into
``/rocopt-release/examples_notebook``. The image also does not include
``git``, so download the folder from the repo tarball with ``curl`` and
Python's built-in ``tarfile``:

.. code-block:: bash

   cd /rocopt-release
   BRANCH=amd-integration
   curl -fsSL "https://github.com/AMD-Ecosystem/rocopt/archive/refs/heads/${BRANCH}.tar.gz" -o /tmp/rocopt.tar.gz
   python3 - <<'EOF'
   import tarfile, os, shutil
   SRC_SUB = "examples_notebook"
   DEST    = "/rocopt-release/examples_notebook"
   with tarfile.open("/tmp/rocopt.tar.gz") as tf:
       root = tf.getnames()[0].split("/")[0]           # e.g. rocopt-amd-integration
       prefix = f"{root}/{SRC_SUB}/"
       for m in tf.getmembers():
           if not m.name.startswith(prefix):
               continue
           rel = m.name[len(prefix):]
           if not rel:
               continue
           out = os.path.join(DEST, rel)
           if m.isdir():
               os.makedirs(out, exist_ok=True)
           else:
               os.makedirs(os.path.dirname(out), exist_ok=True)
               with tf.extractfile(m) as f, open(out, "wb") as g:
                   shutil.copyfileobj(f, g)
   print("Done ->", DEST)
   EOF
   ls -R /rocopt-release/examples_notebook

.. note::

   If ``git`` is available in the image (or you install it with
   ``conda install -y -c conda-forge git``), you can instead clone the repo and
   copy the folder:

   .. code-block:: bash

      git clone --branch amd-integration --single-branch \
        https://github.com/AMD-Ecosystem/rocopt.git /tmp/rocopt
      cp -r /tmp/rocopt/examples_notebook /rocopt-release/

**Install Jupyter.** The docker image does not include Jupyter, so install it:

.. code-block:: bash

   pip install --no-cache-dir notebook ipykernel

3. Fetch the dataset for the vehicle routing notebook
------------------------------------------------------

The Homberger CVRPTW instances are not redistributed inside the repo
(``datasets/**`` is gitignored). Pull them with the in-repo helper, then
expose them at the path the notebook expects:

.. code-block:: bash

   cd /rocopt-release/datasets
   ./get_test_data.sh --cvrptw
   ln -s /rocopt-release/datasets/cvrptw /tmp/data
   ls /tmp/data/C1_10_1.TXT
   cd /rocopt-release

.. note::

   ``get_test_data.sh`` requires ``unzip``, which is not included in the image.
   Install it first, then re-run the script. The ``cuopt_dev`` conda env is the
   most reliable way (``apt`` may be disabled in the image):

   .. code-block:: bash

      conda install -y -c conda-forge unzip

   Alternatively, install it with ``apt`` (run as root):

   .. code-block:: bash

      apt-get update && apt-get install -y unzip

   If you would rather not install anything, extract the already-downloaded
   archives with Python's built-in ``zipfile``:

   .. code-block:: bash

      python3 - <<'EOF'
      import glob, zipfile, os
      for z in glob.glob("/rocopt-release/datasets/**/*.zip", recursive=True):
          with zipfile.ZipFile(z) as zf:
              zf.extractall(os.path.dirname(z))
          print("extracted", z)
      EOF

If ``sintef.no`` is firewalled in your network, fetch the single 1000-customer file manually:

.. code-block:: bash

   mkdir -p /tmp/data && cd /tmp/data
   wget https://www.sintef.no/globalassets/project/top/vrptw/homberger/1000/homberger_1000_customer_instances.zip
   unzip -j homberger_1000_customer_instances.zip C1_10_1.TXT

.. note::
  
  The diet notebooks do not require a dataset.

4. Launch Jupyter
-----------------

.. code-block:: bash

   jupyter notebook \
     --ip 0.0.0.0 --port 8888 \
     --no-browser \
     --NotebookApp.token='' --NotebookApp.password='' \
     --notebook-dir /rocopt-release/examples_notebook

Drop the ``--NotebookApp.token=''`` flags and copy the ``?token=...`` URL from the log if you want authentication.

5. SSH-tunnel to your laptop
-----------------------------

In a fresh terminal on your laptop:

.. code-block:: bash

   ssh -N -L 8888:localhost:8888 <user>@<this-host>

Open http://localhost:8888 to access and run the example notebooks in ``examples_notebook/`` through Jupyter.

Optional: bind-mount the host repo (editing / persistence)
==========================================================

If you want notebook edits to survive container restarts, or you want to use
a local pre-staged dataset directory, mount the host repo and the dataset
directory:

.. code-block:: bash

   docker run -it --rm \
     --name rocopt-jup \
     --device=/dev/kfd --device=/dev/dri \
     --group-add video --ipc=host \
     --shm-size 16G --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
     -p 8888:8888 \
     -v "$HOME/rocopt-working:/workspace" \
     -v "$HOME/rocopt-working/datasets/cvrptw:/tmp/data:ro" \
     -w /workspace \
     rocopt:amd-integration

Then launch Jupyter with ``--notebook-dir /workspace/examples_notebook``.

Per-notebook details
---------------------

The following provide specific details for two of the notebooks. 

Routing benchmark (``cvrptw_benchmark_rocopt.ipynb``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A 1000-customer Gehring & Homberger CVRPTW instance (``C1_10_1``, best known
cost 42 478.95 with 100 vehicles). Restart the kernel and run all cells.
The single solve is capped at 60 s for demo runtime; the upstream NVIDIA
notebook chains a 10 s + 120 s pair.

Run-to-run variance of a few percent is expected. cuOpt's routing solver is
a randomized parallel local-search metaheuristic; identical inputs do not
produce bit-identical outputs across GPU runs.

Diet optimization (``diet_optimization_lp.ipynb`` and ``..._milp.ipynb``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Solve the classic USDA diet LP (and an MILP variant with integer servings)
through the algebraic-modeling Python API.

The solver method is pinned to **PDLP only** (``method=1``) on rocopt. The
default ``method=0`` (Concurrent) launches a Barrier solver thread alongside
PDLP, but Barrier requires cuDSS, which is NVIDIA-only. On rocopt the missing
dispatcher path can deadlock a re-solve of the same ``Problem`` object — most
visibly in the MILP notebook, which solves the LP relaxation twice.
