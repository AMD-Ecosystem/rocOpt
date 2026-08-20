# Reproducing the ROCm test suites

This doc explains how to rebuild the rocopt image, run the C++ gtests and the
Python test suites against an AMD GPU, and interpret the results.  It is the
companion to `scripts/run-tests.sh`, `scripts/build-image.sh`, and the per-test
skip markers documented at the bottom of the file.

If you only want the one-liner, jump to [Happy path](#happy-path).

---

## TL;DR

```bash
# 1. Build the image (uses the current AMD-AIOSS branch, gfx942)
scripts/build-image.sh --branch skip-cudss-server-tests

# 2. Run all suites (C++ gtests + python/cuopt pytests) on a GPU host
scripts/run-tests.sh --image rocopt:skip-cudss-server-tests

# 3. Run the cuopt_server pytests too (not yet wired into run-tests.sh; see below)
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render \
    --ipc=host --shm-size=8G \
    rocopt:skip-cudss-server-tests \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev
        cd /rocopt-release/python/cuopt_server
        pytest -v cuopt_server/tests/
    '
```

Expected outcome on a clean ROCm host:

| Suite                                   | Result                                          |
|-----------------------------------------|-------------------------------------------------|
| C++ gtests                              | All pass (filtered, see `scripts/run-tests.sh`) |
| `python/cuopt/cuopt/tests`              | All pass / pre-existing skips                   |
| `python/cuopt_server/cuopt_server/tests`| `0 failed / 72 passed / 20 skipped` (~6:30)     |

All 20 cuopt_server skips are documented in [What is skipped on ROCm](#what-is-skipped-on-rocm)
below.  Any new failure should fail the run.

---

## Prerequisites

| Component         | Requirement                                                 |
|-------------------|-------------------------------------------------------------|
| Host OS           | Linux with ROCm-capable kernel (tested: Ubuntu 24.04)       |
| GPU               | AMD MI300X (`gfx942`) or compatible CDNA3 part              |
| `/dev/kfd`, `/dev/dri` | Present; user in `video` and `render` groups          |
| Docker            | Daemon running; user can `docker run`                       |
| Disk              | ~30 GB free for the image + datasets                        |
| Network           | Outbound for the conda env + dataset download in the build  |

`scripts/run-tests.sh` will pre-flight all of the above and exit `2` with a
clear message if anything is missing.

---

## ROCm environment variables

All of the ROCm-related env vars the tests need are **baked into the image**
by `dockerfile.rocm`.  You do not need to set anything on the host (other than
ensuring `/dev/kfd` and `/dev/dri` are visible to docker).  The full set:

| Variable                  | Value in image      | Purpose                                                                 |
|---------------------------|---------------------|-------------------------------------------------------------------------|
| `ROCM_PATH`               | `/opt/rocm`         | Canonical ROCm install root                                             |
| `ROCM_HOME`               | `/opt/rocm`         | Alias many tools (CuPy, etc.) look for                                  |
| `HIP_PATH`                | `/opt/rocm`         | HIP runtime root                                                        |
| `HIP_PLATFORM`            | `amd`               | Selects AMD backend (vs. `nvidia`) for HIP                              |
| `CMAKE_HIP_COMPILER`      | `/opt/rocm/bin/amdclang++` | ROCm 7.x preferred HIP compiler                                  |
| `CC` / `CXX`              | `amdclang` / `amdclang++` | C/C++ compilers for in-container rebuilds                         |
| `HCC_AMDGPU_TARGET`       | auto-detected       | Set at conda/shell activation from `rocminfo` (MI300X→gfx942, MI355X→gfx950). Override with `-e HCC_AMDGPU_TARGET=...` if needed. |
| `HSA_ENABLE_SDMA`         | `0`                 | MI300 stability workaround (disables SDMA engines)                      |
| `GPU_MAX_HW_QUEUES`       | `8`                 | MI300 stability workaround (caps hardware queue depth)                  |
| `CUPY_INSTALL_USE_HIP`    | `1`                 | Tells CuPy's installer to build against HIP, not CUDA                   |
| `CMAKE_PREFIX_PATH`       | `/opt/rocm:...`     | Lets CMake find hipBLAS / hipSPARSE / rocThrust                         |
| `LD_LIBRARY_PATH`         | includes `/opt/rocm/lib`, `/opt/rocm/lib64`, `cpp/build/`, ... | `libcuopt.so`, `libmps_parser.so`, ROCm runtime libs are findable |

If you need to inspect or override any of these at runtime:

```bash
# Inside the container
env | grep -E 'ROCM|HIP|HSA|GPU_MAX|AMDGPU'

# Override at docker run time (e.g. to test on a different GPU arch)
docker run --rm -e HCC_AMDGPU_TARGET=gfx90a ... rocopt:...
```

Two host-side knobs worth knowing about:

- **GPU device selection.** `--device=/dev/kfd --device=/dev/dri` exposes
  *all* GPUs visible on the host.  To restrict the container to a specific
  GPU, set `HIP_VISIBLE_DEVICES` (HIP analogue of `CUDA_VISIBLE_DEVICES`):

  ```bash
  docker run --rm -e HIP_VISIBLE_DEVICES=0 ... rocopt:...
  ```

- **CuPy/Numba JIT arch (test/runtime).** `HCC_AMDGPU_TARGET` is detected from
  `rocminfo` on GPU test agents when the conda env activates (see
  `scripts/detect_hcc_amdgpu_target.sh`).  Override with `-e HCC_AMDGPU_TARGET=gfx950`
  if needed.
- **HIP build arch (compile).** CI builder agents are CPU-only.  They always compile
  a multi-arch fat binary (`gfx942;gfx950`) passed as `ROCOPT_GPU_ARCH`.  HIP selects
  the matching code object on the GPU at test/runtime.  Override with
  `--build-arg ROCOPT_GPU_ARCH=...` only for experiments.

---

## Datasets

The C++ gtests and most of the Python suites consume **external dataset
bundles** that are not bundled in the image.  Three download scripts pull
them at runtime, and tests find the data via the `RAPIDS_DATASET_ROOT_DIR`
env var.

### The three download scripts

| Script                                                       | Contents                          | Idempotent?            |
|--------------------------------------------------------------|-----------------------------------|------------------------|
| `datasets/get_test_data.sh`                                  | Routing (VRP, CVRP, CVRPTW, PDPTW, Solomon, ACVRP, distance_engine, ref) | **No** — `rm -rf` + redownload each subdir |
| `datasets/linear_programming/download_pdlp_test_dataset.sh`  | LP / PDLP (datt256, ex10, neos3, qap15, square41, ...)                    | Yes (`wget --continue` / S3 sync)          |
| `datasets/mip/download_miplib_test_dataset.sh`               | MIP / MIPLIB instances                                                    | Yes                                        |

The pre-staged `datasets/cuopt_service_data/` (used by
`test_service_endpoint_with_headers`) lives in the repo itself, not in S3 —
but only ships in the host checkout, not in the image until it's mounted.

### Two download backends

Both `download_*` scripts try **S3 first**, falling back to HTTP if S3
credentials aren't configured.  S3 is faster and required if you're behind a
corporate firewall.  Set these on the **host** before invoking docker, and
forward them into the container:

```bash
# Required: S3 base URI
export CUOPT_DATASET_S3_URI="s3://<bucket>/<prefix>"

# Required if using S3 (the scripts deliberately reject generic AWS_* creds)
export CUOPT_AWS_ACCESS_KEY_ID="..."
export CUOPT_AWS_SECRET_ACCESS_KEY="..."

# Forward to the container
docker run --rm \
    -e CUOPT_DATASET_S3_URI \
    -e CUOPT_AWS_ACCESS_KEY_ID \
    -e CUOPT_AWS_SECRET_ACCESS_KEY \
    ... rocopt:...
```

If none of these are set, the scripts fall back to public HTTPS / wget and
will work but be noticeably slower.

### Where `scripts/run-tests.sh` handles this for you

When you run `scripts/run-tests.sh`, the in-container driver calls
`prepare_datasets()` automatically before either test suite runs:

```
log_step "Preparing test datasets"
  1/3 PDLP datasets
  2/3 MIPLIB datasets
  3/3 Routing datasets (get_test_data.sh)
RAPIDS_DATASET_ROOT_DIR=/rocopt-release/datasets/
```

To skip the (re-)download — useful if you've pre-staged the data via a host
mount — pass `--skip-datasets`:

```bash
scripts/run-tests.sh --skip-datasets
```

This just sets `RAPIDS_DATASET_ROOT_DIR=/rocopt-release/datasets/` without
running the download scripts; tests will fail if the data isn't actually
there.

### Driving the dataset prep manually (for cuopt_server one-shot)

The standalone `docker run ... pytest` recipes below do **not** call
`prepare_datasets()`.  As a result, the tests that depend on
`cuopt_service_data` or `linear_programming/square41` are marked
`@pytest.mark.skip(reason="ROCm infra: ... not mounted")`.  To run them, you
need to either:

**Option A — run the prep inside the container:**

```bash
docker run --rm \
    -e CUOPT_DATASET_S3_URI -e CUOPT_AWS_ACCESS_KEY_ID -e CUOPT_AWS_SECRET_ACCESS_KEY \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render --ipc=host --shm-size=8G \
    rocopt:skip-cudss-server-tests \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev
        cd /rocopt-release
        ./datasets/linear_programming/download_pdlp_test_dataset.sh
        ./datasets/mip/download_miplib_test_dataset.sh
        (cd datasets && ./get_test_data.sh)
        export RAPIDS_DATASET_ROOT_DIR=/rocopt-release/datasets/
        cd python/cuopt_server
        pytest -v cuopt_server/tests/
    '
```

**Option B — mount the host `datasets/` directory:**

```bash
docker run --rm \
    -v "$PWD/datasets:/rocopt-release/datasets:ro" \
    -e RAPIDS_DATASET_ROOT_DIR=/rocopt-release/datasets/ \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render --ipc=host --shm-size=8G \
    rocopt:skip-cudss-server-tests \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev
        cd /rocopt-release/python/cuopt_server
        pytest -v cuopt_server/tests/
    '
```

Option B is the right choice in CI: pre-stage the datasets once on the
Jenkins worker, then bind-mount.

---

## CI-faithful local build (pre-PR)

`scripts/build-image.sh` builds via `dockerfile.rocm` (host-side clone). Jenkins
CI uses nested BuildKit + `docker/Dockerfile.rocm_ci` with local source mounts.
Use the harness in `aisw-ci-builder-tester`:

```bash
cd ../aisw-ci-builder-tester/rocopt
STOP_AFTER_STEP=2 ./scripts/harvest.sh    # builder only (~30–60 min, no GPU)
./scripts/harvest.sh                      # full pipeline (step 5 needs GPU)
```

Artifacts land in `aisw-ci-builder-tester/rocopt/artifacts-local/`.

---

## Happy path

The host-side wrappers do everything the right way; you should only fall back
to the manual flow ([below](#inner-loop-iterating-on-test-fixes)) when you are
iterating on a specific test fix and don't want to rebuild the 26 GB image.

```bash
# Build the image (one-time per branch / per cache miss)
scripts/build-image.sh                       # default: branch=amd-integration, gpu=gfx942
scripts/build-image.sh --branch <your-branch>
scripts/build-image.sh --no-cache            # skip docker layer cache; rare
scripts/build-image.sh --tag rocopt:debug    # extra tag

# Run the tests
scripts/run-tests.sh                         # all suites, default image tag
scripts/run-tests.sh --python                # python only (cuopt, NOT cuopt_server)
scripts/run-tests.sh --cpp                   # C++ gtests only
scripts/run-tests.sh --python -k routing     # pytest -k routing
scripts/run-tests.sh --cpp --ctest-filter "Mps.*"
scripts/run-tests.sh --logdir ./my-logs/     # custom JUnit output dir
```

Outputs:

- **stderr** streams the test logs in real time.
- **stdout** ends with one machine-parseable `RESULT key=value ...` line.
- **JUnit XML** is written under `--logdir` (default `./test-logs/<utc-ts>/`)
  — these files are the canonical Jenkins artifact.

Exit codes are consistent across both scripts:

| Code | Meaning                                                       |
|------|---------------------------------------------------------------|
| 0    | All selected suites passed                                    |
| 1    | One or more suites had test failures                          |
| 2    | Infrastructure problem (no docker, no GPU, image missing, ... )|
| 3    | Usage error (bad flag, missing arg, ...)                      |

---

## What `run-tests.sh --python` covers (and what it doesn't)

The current `scripts/run-tests.sh --python` path runs only the **`python/cuopt/cuopt/tests`**
suite, via `ci/run_cuopt_pytests.sh`.  It does **not** run the
`python/cuopt_server/cuopt_server/tests` suite.

That second suite has its own quirks (a real uvicorn subprocess is spawned via
the `cuoptproc` fixture, hard-coded ports, real HTTP traffic), so until it is
wired into the in-container driver it has to be invoked separately.  See
[Running the cuopt_server suite](#running-the-cuopt_server-suite) below.

A natural follow-up is to extend `scripts/lib/in-container-tests.sh` to call
both wrappers and aggregate both JUnit XMLs into the same logdir.

---

## Running the `cuopt_server` suite

The fastest way is to exec into a fresh container off the image and run pytest
directly.  The host-side wrapper handles the device flags; we then drop into
the right directory and invoke pytest.

> **Note on datasets.** The recipes below do **not** run dataset download.
> Tests that depend on `cuopt_service_data/` or `linear_programming/square41`
> are skipped (see the [Datasets](#datasets) section for how to un-skip them
> via host mount or in-container download).  This is intentional — the
> baseline of `0 failed / 72 passed / 20 skipped` assumes the no-dataset
> path.  If you mount/download datasets, expect 3 fewer skips and 3 more
> passes.

### Already inside a running container (the most common case)

If you already have a bash shell open inside a built rocopt container (the
prompt looks like `(cuopt_dev) root@ctr-...:/rocopt-release#`), skip the
`docker run` flags entirely.  The image's defaults are already in effect —
ROCm env vars, conda env, library paths.

```bash
# Activate the conda env (no-op if your prompt already shows (cuopt_dev))
source /root/miniforge3/bin/activate cuopt_dev

# Go to the right directory.  Pytest's rootdir + conftest live under
# python/cuopt_server, and the upstream wrapper expects this cwd.
cd /rocopt-release/python/cuopt_server

# Full suite, tee the log so it survives outside the container
pytest -v cuopt_server/tests/ 2>&1 \
    | tee /rocopt/rocopt-working/cuopt_server_pytest.log

# One specific test, with -s so prints from the server subprocess show up
pytest -v -s cuopt_server/tests/test_server.py::test_service_endpoint

# Restrict by pytest keyword
pytest -v cuopt_server/tests/ -k "lp or routing"

# Re-run just the failures from the previous run
pytest -v --lf cuopt_server/tests/
```

Expected tail of a full run:

```
====== 0 failed, 72 passed, 20 skipped, 16 warnings in ~390s (0:06:30) =======
```

A few useful flags to know:

| Flag                       | Effect                                                    |
|----------------------------|-----------------------------------------------------------|
| `-v`                       | Verbose — print each test name as it runs                 |
| `-s`                       | Don't capture stdout/stderr — see server subprocess logs  |
| `-x`                       | Stop on first failure                                     |
| `--lf`                     | Run only tests that failed in the previous session        |
| `-k "expr"`                | Filter by name (boolean: `"abort and not cuopt"`)         |
| `--junitxml=/out/x.xml`    | Emit JUnit XML for Jenkins                                |
| `--collect-only`           | List which tests *would* run; doesn't execute             |

The `tee` target `/rocopt/rocopt-working/cuopt_server_pytest.log` is on a
host-mounted volume, so the log survives even if you `exit` the container.
On the host it's at `~/rocopt-working/cuopt_server_pytest.log`.

If the container is **not** currently running, see the [next two recipes](#one-shot-good-for-ci)
for how to start one with the right device flags.

### One-shot (good for CI)

```bash
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render \
    --ipc=host --shm-size=8G --security-opt seccomp=unconfined \
    -v "$PWD/cuopt-server-logs:/out" \
    rocopt:skip-cudss-server-tests \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev
        cd /rocopt-release/python/cuopt_server
        pytest -v --junitxml=/out/cuopt_server.xml cuopt_server/tests/
    '
```

Expected tail of the run:

```
====== 0 failed, 72 passed, 20 skipped, 16 warnings in ~390s (0:06:30) =======
```

If you see a different number of `passed`/`skipped`, see the
[What is skipped on ROCm](#what-is-skipped-on-rocm) section — collection drift
in upstream merges may shift counts without indicating regressions.

### Interactive (good for inner-loop debugging)

```bash
docker run -it --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render \
    --ipc=host --shm-size=8G \
    -v "$HOME/rocopt-working:/rocopt/rocopt-working" \
    rocopt:skip-cudss-server-tests bash

# Inside the container:
source /root/miniforge3/bin/activate cuopt_dev
cd /rocopt-release/python/cuopt_server

# Full suite
pytest -v cuopt_server/tests/

# One test
pytest -v -s cuopt_server/tests/test_server.py::test_service_endpoint

# Restrict by keyword
pytest -v cuopt_server/tests/ -k "lp or routing"
```

---

## Running the `cuopt_self_hosted` suite

Unlike `cuopt_server` (whose `cuoptproc` fixture spawns its own uvicorn
subprocess), the `cuopt_self_hosted` tests under
`python/cuopt_self_hosted/tests/` do **not** start a server. They construct a
`CuOptServiceSelfHostClient` and talk over HTTP to an **already-running**
`cuopt_service`, discovering it via the `CUOPT_SERVER_PORT` env var (default
`5000`):

```python
port = os.environ.get("CUOPT_SERVER_PORT", 5000)
client = CuOptServiceSelfHostClient(port=port, ...)
```

So you must start the service yourself, then point the tests at it. This is
exactly what CI does (`aisw-ci-builder-tester/rocopt/generic/tester/entrypoint.sh`
and the code-coverage tester). Port `5050` is used deliberately instead of the
default to sidestep the port-5000/5555 collisions described in
[Interpreting failures](#rocm-specific-infrastructure-failures).

### One-shot (matches CI)

```bash
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render \
    --ipc=host --shm-size=8G --security-opt seccomp=unconfined \
    -v "$PWD/cuopt-self-hosted-logs:/out" \
    rocopt:skip-cudss-server-tests \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev

        # 1. Clear any stale service, then start a fresh one on 5050.
        pkill -f "cuopt_server.cuopt_service" || true
        ROCM_HOME=/opt/rocm \
            python -m cuopt_server.cuopt_service --port 5050 \
                >/out/cuopt_service.log 2>&1 &
        SH_PID=$!

        # 2. Health-poll for up to 30s (bail early if the PID dies).
        for _ in $(seq 1 30); do
            kill -0 "$SH_PID" 2>/dev/null || { echo "service died"; break; }
            wget -qO- "http://127.0.0.1:5050/cuopt/health" >/dev/null 2>&1 && break
            sleep 1
        done

        # 3. Run the suite against it.
        cd /rocopt-release/python/cuopt_self_hosted
        CUOPT_SERVER_PORT=5050 \
            PYTHONPATH="/rocopt-release/python/cuopt_self_hosted:${PYTHONPATH:-}" \
            pytest -v --junitxml=/out/cuopt_self_hosted.xml tests/

        # 4. Tear down.
        kill -TERM "$SH_PID" 2>/dev/null || true
        wait "$SH_PID" 2>/dev/null || true
    '
```

If the health poll times out, inspect `cuopt-self-hosted-logs/cuopt_service.log`
— on a shared host the most common cause is a stale `cuopt_service` still
holding the port (re-run the `pkill` line) or a GPU that is busy/unavailable.

### Interactive (inner-loop debugging)

```bash
# Inside a running container (prompt shows (cuopt_dev) root@...:/rocopt-release#):
source /root/miniforge3/bin/activate cuopt_dev
pkill -f 'cuopt_server.cuopt_service' || true
python -m cuopt_server.cuopt_service --port 5050 >/tmp/cuopt_service.log 2>&1 &
# wait for http://127.0.0.1:5050/cuopt/health to return, then:
cd /rocopt-release/python/cuopt_self_hosted
CUOPT_SERVER_PORT=5050 pytest -v tests/
```

---

## Inner loop: iterating on test fixes

When you are changing test code (or product code that affects tests) and don't
want to rebuild the 26 GB image, the established workflow is to keep the host
repo at `~/rocopt-working/` and mount it into the running container.

### Host side

Make your edits in the regular git checkout (e.g. `~/rocopt/`), commit when
ready, and stage the file into the working dir that the container mounts:

```bash
# Whenever you change a source file:
cp ~/rocopt/<path-to-edited-file> ~/rocopt-working/<path-to-edited-file>
```

This step is necessary because the running container only sees
`~/rocopt-working/` (mounted to `/rocopt/rocopt-working/`), not the git
checkout.

### Container side

Promote the edited file into the installed test tree, then rerun the affected
test:

```bash
cp /rocopt/rocopt-working/<path>   /rocopt-release/<path>
cd /rocopt-release/python/cuopt_server
pytest -v -s cuopt_server/tests/<test_file>::<test_name>
```

Mount layout cheat-sheet:

| Host path                                   | Container path                                  |
|---------------------------------------------|-------------------------------------------------|
| `~/rocopt-working/`                         | `/rocopt/rocopt-working/`                       |
| `~/rocopt/` (git checkout)                  | not mounted                                     |
| (baked into image during `build-image.sh`)  | `/rocopt-release/`                              |

Once a change is validated, commit it in `~/rocopt/`, push, and rebuild the
image so the change becomes part of the baseline (`scripts/build-image.sh --branch <yours>`).

---

## Interpreting failures

### Real product failures

These show up as `assert ... == ...` mismatches, solver status mismatches, or
crashes in HIP code paths.  Treat them like any other regression: bisect on
git, attach a minimal reproducer, file an issue.

### ROCm-specific infrastructure failures

Several test failures we have seen are **not** product bugs but artifacts of
the ROCm test container.  Each is marked with `@pytest.mark.skip(reason=...)`
explaining the issue and the keyword `ROCm infra:` so they're greppable:

```bash
grep -rnB1 -A5 'ROCm infra:' python/cuopt_server/cuopt_server/tests/
```

The two recurring infra issues are:

1. **Hard-coded port 5555 / 5000 collisions.**  The `cuoptproc` fixture
   spawns a uvicorn subprocess on a hard-coded port; when prior test sessions
   leave stale processes behind, the fixture silently fails to bind, the test
   runs against the stale server, and gets a wrong status code (usually 422
   or a missing-asset error).  Symptom: test runs in well under one second
   and returns an HTTP response that doesn't match the spawn-fresh path.

   Workaround during iteration:

   ```bash
   pkill -f cuopt_service || true
   pkill -f 'uvicorn.*cuopt_server' || true
   ```

2. **Missing dataset bundles.**  The `cuopt_service_data` and
   `linear_programming/square41` dataset bundles exist on the host but are
   not mounted into the container at the path `RAPIDS_DATASET_ROOT_DIR` points
   to.  Symptom: test fails with a file-not-found assertion or an HTTP 4xx
   from a server that can't load its asset.

   These are skipped on ROCm until the dataset stage gets folded into
   `dockerfile.rocm` (or until `scripts/run-tests.sh` mounts the host
   `datasets/` dir).

If a test you expected to run is now `SKIPPED` with a `ROCm infra:` reason,
check whether the infra has actually been fixed and consider removing the skip.

---

## What is skipped on ROCm

The full inventory of ROCm-specific skips in `python/cuopt_server/cuopt_server/tests/`:

| Test                                                    | File                       | Reason                                  |
|---------------------------------------------------------|----------------------------|-----------------------------------------|
| `test_sample_lp`                                        | `test_lp.py`               | Port 5555 collision (infra)             |
| `test_sample_milp[*]` (4 params)                        | `test_lp.py`               | MIP B&B needs cuDSS (not in ROCm)       |
| `test_barrier_solver_options[*]` (8 params)             | `test_lp.py`               | Barrier needs cuDSS                     |
| `test_warmstart`                                        | `test_pdlp_warmstart.py`   | Dataset `square41.mps` not mounted      |
| `test_abort_on_complete`, `test_abort_of_running`       | `test_job_abort.py`        | Dataset `good_lp.json` not mounted      |
| `test_server_health[default]`                           | `test_server_health.py`    | Port 5000 collision (infra)             |
| `test_service_endpoint_with_headers`                    | `test_server.py`           | Port 5555 collision (infra)             |
| `test_time_limit_logs`                                  | `test_bill_logging.py`     | Pre-existing upstream skip              |
| `test_incumbent_callback`                               | `test_incumbents.py`       | Pre-existing upstream skip              |
| `test_solver_logging`                                   | `test_solver_logging.py`   | Pre-existing upstream skip              |

Total: **20 skipped** when the suite is healthy.  If the number drops, that's
fine (an infra issue was fixed).  If it rises *and* something changed in our
fork, audit the new skip with `git blame`.

---

## CI integration

A Jenkins job should approximate:

```bash
set -e
scripts/build-image.sh --branch "${GIT_BRANCH}" --tag "rocopt:${GIT_COMMIT:0:7}"
scripts/run-tests.sh --image "rocopt:${GIT_COMMIT:0:7}" --logdir "${WORKSPACE}/test-logs"

# Until cuopt_server is wired into run-tests.sh, drive it separately:
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add=video --group-add=render \
    --ipc=host --shm-size=8G \
    -v "${WORKSPACE}/test-logs:/out" \
    "rocopt:${GIT_COMMIT:0:7}" \
    bash -lc '
        source /root/miniforge3/bin/activate cuopt_dev
        cd /rocopt-release/python/cuopt_server
        pytest --junitxml=/out/cuopt_server.xml cuopt_server/tests/
    '
```

Archive the `test-logs/` directory; Jenkins' JUnit publisher picks up
`pytest.xml`, `ctest.xml`, and `cuopt_server.xml` automatically.

A useful guardrail is to fail the build if the skip count drops below 20 *and*
the suite has new failures, or rises above 25 without a corresponding commit
touching test files.  This catches both regressions and silent skip-creep.

---

## Files referenced in this doc

- `scripts/build-image.sh` — host-side image builder
- `scripts/run-tests.sh` — host-side test runner (C++ + python/cuopt only today)
- `scripts/lib/in-container-tests.sh` — single source of truth for in-container test orchestration
- `ci/run_cuopt_pytests.sh` — upstream wrapper for `python/cuopt/cuopt/tests`
- `ci/run_cuopt_server_pytests.sh` — upstream wrapper for `python/cuopt_server/cuopt_server/tests`
- `dockerfile.rocm` — image definition
- `python/cuopt_server/cuopt_server/tests/` — server-side pytest suite (the one with the ROCm skips)
- `python/cuopt_self_hosted/tests/` — self-hosted client suite (needs an external `cuopt_service`; see [Running the `cuopt_self_hosted` suite](#running-the-cuopt_self_hosted-suite))
