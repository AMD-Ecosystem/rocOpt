# SPDX-FileCopyrightText: Copyright (c) 2022-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import os
import shutil
import signal
import threading
import time
from subprocess import Popen, TimeoutExpired
from typing import Dict, List, Optional

import pytest
import requests

# ---------------------------------------------------------------------------
# TestClient mode (CUOPT_TEST_TESTCLIENT=1)
# ---------------------------------------------------------------------------
# By default the cuopt_server tests spin up `python -m cuopt_server.cuopt_service`
# as an out-of-process subprocess (see `cuoptproc` fixture and `RequestClient`
# below) and drive it over HTTP via `requests`. That's the production code
# path, but it has a serious blast radius for *coverage*: nothing the
# webserver / solver workers run is recorded in the pytest process's
# coverage data, the subprocess gets SIGKILL'd on shutdown, and the
# subprocess-shim coverage fragments don't survive that (see Path-1
# investigation in scripts/lib/python-coverage-shim/sitecustomize.py).
#
# When CUOPT_TEST_TESTCLIENT=1, the same FastAPI app is hosted *inside the
# pytest process* via starlette's TestClient, and the solver workers run as
# `multiprocessing.Process` children of pytest. Concretely:
#
#   pytest process                          (pytest-cov instruments this)
#     ├─ webserver.app via TestClient       (records routes/handlers)
#     ├─ receive_results thread             (records results-loop code)
#     └─ multiprocessing.Process workers    (per-worker .coverage fragment
#                                            via concurrency=multiprocessing)
#
# RequestClient.{post,get,delete} transparently route through TestClient
# instead of `requests`, so individual test files don't need to change.
_USE_TESTCLIENT = os.environ.get("CUOPT_TEST_TESTCLIENT") == "1"
_TC_STATE: Dict[str, object] = {}

# Polling ceiling for poll_for_completion. The legacy / Popen path retains
# the original 600s because real HTTP can be slow and the cuopt_service
# subprocess may legitimately take a while to start solving. In TestClient
# mode the worker is in-process and a healthy solver always produces a
# result in seconds, so polling longer than ~30s only buys waiting on
# failure modes (dead worker, missing watch_solvers, etc.). Override at
# the env-var level via CUOPT_TEST_POLL_MAX_SECONDS if a slow test needs
# more headroom; default is 30s in TestClient mode, 600s otherwise.
_POLL_MAX_SECONDS = int(
    os.environ.get(
        "CUOPT_TEST_POLL_MAX_SECONDS",
        "30" if _USE_TESTCLIENT else "600",
    )
)

RAPIDS_DATASET_ROOT_DIR = os.getenv("RAPIDS_DATASET_ROOT_DIR")
if RAPIDS_DATASET_ROOT_DIR is None:
    RAPIDS_DATASET_ROOT_DIR = os.path.dirname(os.getcwd())
    RAPIDS_DATASET_ROOT_DIR = os.path.join(RAPIDS_DATASET_ROOT_DIR, "datasets")


def generate_json_data(**args):
    return {arg[0]: arg[1] for arg in args.items() if arg[1] is not None}


def delete_request(client, reqId, queued=None, running=None):
    params = {}
    if queued is not None:
        params["queued"] = queued

    if running is not None:
        params["running"] = running
    headers = {"Accept": "application/json"}
    return client.delete(
        f"/cuopt/request/{reqId}", headers=headers, params=params
    )


def poll_request(client, reqId):
    return client.get(f"/cuopt/solution/{reqId}")


def get_lp(client, data):
    headers = {"CLIENT-VERSION": "custom"}

    return client.post("/cuopt/request", headers=headers, params={}, json=data)


def get_routes(
    client,
    cost_waypoint_graph: Optional[Dict] = None,
    travel_time_waypoint_graph: Optional[Dict] = None,
    cost_matrix: Optional[Dict[int, List[List[float]]]] = None,
    travel_time_matrix: Optional[Dict[int, List[List[float]]]] = None,
    vehicle_locations: Optional[List[List[int]]] = None,
    vehicle_ids: Optional[List[str]] = None,
    capacities: Optional[List[List[int]]] = None,
    vehicle_time_windows: Optional[List[List[float]]] = None,
    vehicle_breaks: Optional[List[Dict]] = None,
    vehicle_break_time_windows: Optional[List[List[List[int]]]] = None,
    vehicle_break_durations: Optional[List[List[int]]] = None,
    vehicle_break_locations: Optional[List[int]] = None,
    vehicle_types: Optional[List[int]] = None,
    vehicle_order_match: Optional[List[dict]] = None,
    skip_first_trips: Optional[List[bool]] = None,
    drop_return_trips: Optional[List[bool]] = None,
    min_vehicles: Optional[int] = None,
    vehicle_max_costs: Optional[List[float]] = None,
    vehicle_max_times: Optional[List[float]] = None,
    vehicle_fixed_costs: Optional[List[float]] = None,
    task_locations: Optional[List[int]] = None,
    demand: Optional[List[List[int]]] = None,
    pickup_and_delivery_pairs: Optional[List[List[int]]] = None,
    task_time_windows: Optional[List[List[float]]] = None,
    service_times: Optional[List[float]] = None,
    prizes: Optional[List[float]] = None,
    order_vehicle_match: Optional[List[dict]] = None,
    time_limit: Optional[float] = None,
    objectives: Optional[dict] = None,
    config_file: Optional[str] = None,
    verbose_mode: Optional[bool] = None,
    error_logging: Optional[bool] = None,
    validation_only: Optional[bool] = False,
    cache: Optional[bool] = None,
    reqId: Optional[str] = None,
    result_timeout: Optional[int] = None,
    initialId: Optional[List[str]] = None,
    delete=True,
):
    options = {}
    options["cost_waypoint_graph_data"] = generate_json_data(
        waypoint_graph=cost_waypoint_graph
    )

    options["travel_time_waypoint_graph_data"] = generate_json_data(
        waypoint_graph=travel_time_waypoint_graph
    )

    options["cost_matrix_data"] = generate_json_data(data=cost_matrix)

    options["travel_time_matrix_data"] = generate_json_data(
        data=travel_time_matrix
    )

    # fleet data
    options["fleet_data"] = generate_json_data(
        vehicle_ids=vehicle_ids,
        vehicle_locations=vehicle_locations,
        capacities=capacities,
        vehicle_time_windows=vehicle_time_windows,
        vehicle_breaks=vehicle_breaks,
        vehicle_break_time_windows=vehicle_break_time_windows,
        vehicle_break_durations=vehicle_break_durations,
        vehicle_break_locations=vehicle_break_locations,
        vehicle_types=vehicle_types,
        vehicle_order_match=vehicle_order_match,
        skip_first_trips=skip_first_trips,
        drop_return_trips=drop_return_trips,
        min_vehicles=min_vehicles,
        vehicle_max_costs=vehicle_max_costs,
        vehicle_max_times=vehicle_max_times,
        vehicle_fixed_costs=vehicle_fixed_costs,
    )

    # task data
    options["task_data"] = generate_json_data(
        task_locations=task_locations,
        demand=demand,
        pickup_and_delivery_pairs=pickup_and_delivery_pairs,
        task_time_windows=task_time_windows,
        service_times=service_times,
        prizes=prizes,
        order_vehicle_match=order_vehicle_match,
    )

    # solver config
    options["solver_config"] = generate_json_data(
        time_limit=time_limit,
        objectives=objectives,
        config_file=config_file,
        verbose_mode=verbose_mode,
        error_logging=error_logging,
    )

    params = {"validation_only": validation_only}

    if cache is not None:
        params["cache"] = cache
    if reqId is not None:
        params["reqId"] = reqId
    if initialId is not None:
        params["initialId"] = initialId

    headers = {"CLIENT-VERSION": "custom"}

    return client.post(
        "/cuopt/request",
        headers=headers,
        params=params,
        json=options,
        block=cache is None and result_timeout is None,
        delete=delete,
    )


def cuopt_service_sync(
    client,
    action: str,
    cost_waypoint_graph: Optional[Dict] = None,
    travel_time_waypoint_graph: Optional[Dict] = None,
    cost_matrix: Optional[Dict[int, List[List[float]]]] = None,
    travel_time_matrix: Optional[Dict[int, List[List[float]]]] = None,
    vehicle_locations: Optional[List[List[int]]] = None,
    vehicle_ids: Optional[List[str]] = None,
    capacities: Optional[List[List[int]]] = None,
    vehicle_time_windows: Optional[List[List[float]]] = None,
    vehicle_breaks: Optional[List[Dict]] = None,
    vehicle_break_time_windows: Optional[List[List[List[int]]]] = None,
    vehicle_break_durations: Optional[List[List[int]]] = None,
    vehicle_break_locations: Optional[List[int]] = None,
    vehicle_types: Optional[List[int]] = None,
    vehicle_order_match: Optional[List[dict]] = None,
    skip_first_trips: Optional[List[bool]] = None,
    drop_return_trips: Optional[List[bool]] = None,
    min_vehicles: Optional[int] = None,
    vehicle_max_costs: Optional[List[float]] = None,
    vehicle_max_times: Optional[List[float]] = None,
    vehicle_fixed_costs: Optional[List[float]] = None,
    task_locations: Optional[List[int]] = None,
    demand: Optional[List[List[int]]] = None,
    pickup_and_delivery_pairs: Optional[List[List[int]]] = None,
    task_time_windows: Optional[List[List[float]]] = None,
    service_times: Optional[List[float]] = None,
    prizes: Optional[List[float]] = None,
    order_vehicle_match: Optional[List[dict]] = None,
    time_limit: Optional[float] = None,
    objectives: Optional[dict] = None,
    config_file: Optional[str] = None,
    verbose_mode: Optional[bool] = None,
    error_logging: Optional[bool] = None,
):
    options = {}
    options["cost_waypoint_graph_data"] = generate_json_data(
        waypoint_graph=cost_waypoint_graph
    )

    options["travel_time_waypoint_graph_data"] = generate_json_data(
        waypoint_graph=travel_time_waypoint_graph
    )

    options["cost_matrix_data"] = generate_json_data(data=cost_matrix)

    options["travel_time_matrix_data"] = generate_json_data(
        data=travel_time_matrix
    )

    # fleet data
    options["fleet_data"] = generate_json_data(
        vehicle_ids=vehicle_ids,
        vehicle_locations=vehicle_locations,
        capacities=capacities,
        vehicle_time_windows=vehicle_time_windows,
        vehicle_breaks=vehicle_breaks,
        vehicle_break_time_windows=vehicle_break_time_windows,
        vehicle_break_durations=vehicle_break_durations,
        vehicle_break_locations=vehicle_break_locations,
        vehicle_types=vehicle_types,
        vehicle_order_match=vehicle_order_match,
        skip_first_trips=skip_first_trips,
        drop_return_trips=drop_return_trips,
        min_vehicles=min_vehicles,
        vehicle_max_costs=vehicle_max_costs,
        vehicle_max_times=vehicle_max_times,
        vehicle_fixed_costs=vehicle_fixed_costs,
    )

    # task data
    options["task_data"] = generate_json_data(
        task_locations=task_locations,
        demand=demand,
        pickup_and_delivery_pairs=pickup_and_delivery_pairs,
        task_time_windows=task_time_windows,
        service_times=service_times,
        prizes=prizes,
        order_vehicle_match=order_vehicle_match,
    )

    # solver config
    options["solver_config"] = generate_json_data(
        time_limit=time_limit,
        objectives=objectives,
        config_file=config_file,
        verbose_mode=verbose_mode,
        error_logging=error_logging,
    )

    cuopt_service_data = generate_json_data(
        action=action,
        data=options,
    )

    return client.post(
        "/cuopt/cuopt",
        headers={"CLIENT-VERSION": "custom"},
        json=cuopt_service_data,
    )


# Fixture and client to allow full cuopt service
# to run as a separate process for multiple tests
cuoptmain = None
# Use module name instead of file path to ensure we use the installed package
server_script = "-m"
server_module = "cuopt_server.cuopt_service"
python_path = shutil.which("python")


def cleanup_cuopt_process():
    """Clean up the cuopt process if it's still running"""
    global cuoptmain
    if cuoptmain and cuoptmain.poll() is None:
        cuoptmain.terminate()
        try:
            cuoptmain.wait(timeout=5)
        except TimeoutExpired:
            cuoptmain.kill()
            cuoptmain.wait()


def signal_handler(signum, frame):
    """Handle interrupt signals to ensure cleanup"""
    cleanup_cuopt_process()
    exit(1)


# Register signal handlers for cleanup. These exist to SIGKILL the Popen'd
# cuopt_service subprocess when pytest itself is interrupted -- they have
# no work to do in TestClient mode (there is no subprocess to kill) and
# the unconditional exit(1) actually breaks teardown in that mode because
# fixture cleanup raises SystemExit through pytest's fixture machinery.
if not _USE_TESTCLIENT:
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)


def spinup_wait():
    client = RequestClient()
    count = 0
    result = None
    while True:
        count += 1
        if count == 30:
            break
        try:
            result = client.get("/cuopt/health")
            break
        except Exception:
            time.sleep(1)
    assert result.status_code == 200


def _coverage_save_current():
    """Best-effort flush of the currently-active Coverage instance.

    Called from inside the solver worker (a forked multiprocessing child).
    coverage.py's `concurrency = multiprocessing` patch wraps
    BaseProcess._bootstrap so cov.save() runs in a `finally` block when
    the target returns -- but that only fires on the clean-exit path
    (ExitJob -> break -> return from process_async_solve). If the worker
    is hit by SIGKILL while solving (because production's
    `signal.signal(SIGTERM, SIG_IGN)` made our teardown's w.terminate()
    a no-op and we escalated to w.kill()), atexit/finally never runs.
    This helper makes any flush deterministic at points we control.
    """
    try:
        import coverage  # type: ignore[import-not-found]
    except ImportError:
        return
    try:
        cov = coverage.Coverage.current()
        if cov is not None:
            cov.save()
    except Exception:
        pass


def _install_solver_coverage_shim(solver_module):
    """Replace solver.process_async_solve with a coverage-aware wrapper.

    Two problems this fixes -- both only relevant under
    CUOPT_TEST_TESTCLIENT=1 (in production this wrapping is never
    installed):

      1. process_async_solve sets `signal.signal(SIGTERM, SIG_IGN)` at
         line 356 to harden the worker against stray child-termination
         signals. That makes our teardown's `w.terminate()` (SIGTERM) a
         no-op, so we end up SIGKILL'ing the worker -- which bypasses
         coverage's atexit save. Under the wrapper we (a) install our
         own SIGTERM handler BEFORE calling the original, and (b)
         monkey-patch signal.signal inside the worker so production's
         `signal.signal(SIGTERM, SIG_IGN)` is silently dropped and our
         handler stays installed.
      2. Even on the clean ExitJob exit path, the multiprocessing.popen_fork
         child calls `os._exit(code)` after _bootstrap returns -- bypassing
         atexit. coverage's ProcessWithCoverage._bootstrap.finally does
         cov.save() before that os._exit, so this normally works -- but
         we add an explicit cov.save() in our wrapper's finally too as
         belt-and-suspenders. (Two saves are idempotent: the second one
         either no-ops or writes a same-named fragment.)

    The wrapper preserves production semantics for non-test runs by
    being installed only inside _setup_testclient_inprocess.
    """
    import os
    import signal as _signal

    if getattr(solver_module.process_async_solve, "_cuopt_cov_wrapped", False):
        return

    _orig = solver_module.process_async_solve

    def _flush_and_exit(signum, frame):
        _coverage_save_current()
        # _exit (not sys.exit) so we don't run arbitrary atexit handlers
        # that might re-enter coverage or queue cleanup mid-signal.
        os._exit(0)

    def _wrapped(*args, **kwargs):
        # Install our SIGTERM handler first. process_async_solve will try
        # to overwrite it shortly with SIG_IGN; the _refuse_ignore wrapper
        # below intercepts that attempt.
        _signal.signal(_signal.SIGTERM, _flush_and_exit)

        _orig_signal_signal = _signal.signal

        def _refuse_sigterm_ignore(signum, handler):
            # Production's `signal.signal(SIGTERM, SIG_IGN)` at the top of
            # process_async_solve would re-mask SIGTERM. Drop that specific
            # call so our flush-and-exit handler stays installed; allow
            # everything else (SIGCHLD, SIGINT, etc.) to pass through.
            if signum == _signal.SIGTERM and handler == _signal.SIG_IGN:
                return _orig_signal_signal(_signal.SIGTERM, _flush_and_exit)
            return _orig_signal_signal(signum, handler)

        _signal.signal = _refuse_sigterm_ignore  # type: ignore[assignment]
        try:
            return _orig(*args, **kwargs)
        finally:
            # Restore the (possibly-already-sitecustomize-wrapped)
            # signal.signal so we don't leak the monkey-patch.
            _signal.signal = _orig_signal_signal  # type: ignore[assignment]
            _coverage_save_current()

    _wrapped._cuopt_cov_wrapped = True  # type: ignore[attr-defined]
    solver_module.process_async_solve = _wrapped


def _test_watch_solvers(
    app_exit, job_queue, results_queue, abort_queue, abort_list, process_handler
):
    """Pytest-safe variant of process_handler.watch_solvers.

    The production watcher does two jobs:
      1. Drain abort_queue: when DELETE /cuopt/request/{reqId} runs, SIGKILL
         the worker that's actually executing reqId, then spawn a fresh
         worker so the pool still has one ready for the next request.
      2. Auto-heal: any worker whose process.is_alive() returns False gets
         silently respawned.

    Job 1 is correct for tests too -- test_job_abort.py and test_job_cache.py
    need it. Job 2 is *actively harmful* inside pytest:

      A worker that OOMs at startup (e.g. `rmm.mr.PoolMemoryResource(...)`
      hits its 1 GiB cap while the prior worker's HIP context is still
      tearing down) will die immediately. The watcher then spawns a
      replacement on the same GPU, which immediately OOMs the same way,
      which the watcher spawns a replacement for... A single transient
      RMM failure becomes a 76-process cascade in ~20 seconds, the real
      first failure scrolls off the top of the log, and the watcher
      itself eventually races its own dict and dies with
        KeyError at process_handler.py:134  s_procs[pid].gpuid

    This variant therefore only does Job 1. A worker dying in pytest will
    surface as one clean test failure with the real RMM traceback at the
    top of the log -- which is what we want from a test harness.
    """
    import queue as _q

    while True:
        try:
            abort_id = abort_queue.get(timeout=0.5)
        except _q.Empty:
            if app_exit.is_set():
                return
            continue

        if app_exit.is_set():
            return

        s_procs = process_handler.get_solver_processes()
        process_handler.kill_pid(abort_id)
        if abort_id in s_procs:
            gpuid = s_procs[abort_id].gpuid
            del s_procs[abort_id]
            process_handler.create_process(
                app_exit, job_queue, results_queue, abort_list, gpuid
            )


def _setup_testclient_inprocess():
    """In-process equivalent of `python -m cuopt_server.cuopt_service`.

    Mirrors the subset of `cuopt_service.__main__` and `webserver.run_server`
    that the tests actually exercise:

      * Initialise `request_filter` tier (mock_store and the
        /cuopt/cuopt endpoint both read it on each request).
      * Allocate the inter-process queues (job/results/abort), the
        app_exit / jobs_marked_done Events, and the abort_list shared dict.
      * Wire those into webserver.* via `set_queues_and_flags`.
      * Spawn a single solver worker as a multiprocessing.Process
        (matches `cuopt_service.__main__`'s per-GPU spawn loop with
        gpu_count=1, procs_per_gpu=1).
      * Start the receive_results thread inside the pytest process.
      * Construct a starlette TestClient on `webserver.app`.

    We deliberately do NOT start the `heartbeat` thread: heartbeat calls
    `terminate_pid(parent)` when receive_results dies, and `parent` here
    is the pytest process. Tests don't need that watchdog.

    Returns a dict of teardown handles consumed by `_teardown_testclient`.
    """
    from multiprocessing import Event, Queue

    from fastapi.testclient import TestClient

    from cuopt_server import webserver
    from cuopt_server.utils import (
        health_check,
        process_handler,
        request_filter,
        solver as _solver_mod,
    )
    from cuopt_server.utils.job_queue import ExitJob, Shutdown, create_abort_list

    # IMPORTANT: install BEFORE create_process(). Process(target=...) captures
    # the target reference at construction time, so the monkey-patch has to
    # be in place before that line for the forked worker to run the wrapped
    # version. See _install_solver_coverage_shim for what this does and why.
    _install_solver_coverage_shim(_solver_mod)

    app_exit = Event()
    jobs_marked_done = Event()
    job_queue = Queue()
    abort_queue = Queue()
    results_queue = Queue()
    abort_list = create_abort_list()

    request_filter.set_tier("managed_default")
    webserver.set_queues_and_flags(app_exit, job_queue, abort_queue, abort_list)
    health_check.health_init()

    # One worker is enough for the test workload (matches the in-CI default
    # of CUOPT_GPU_COUNT=1, CUOPT_PROCS_PER_GPU=1). gpu_id=None mirrors
    # `cuopt_service.__main__`'s "we failed to read nvidia-smi" fallback.
    process_handler.create_process(
        app_exit, job_queue, results_queue, abort_list, gpu_id=None
    )
    workers = [s.process for s in process_handler.get_solver_processes().values()]

    # receive_results runs inside pytest so the result_lock + saved_results
    # dict that the GET /cuopt/solution/{id} handler reads are populated
    # by jobs the worker pushes onto results_queue.
    #
    # CRITICAL: receive_results calls `terminate_pid(parent)` (= SIGTERM
    # to its parent PID) when it sees a Shutdown sentinel -- which is its
    # production shutdown contract: receive_results runs inside the
    # webserver multiprocessing.Process and SIGTERMs that Process to bring
    # it down. In-process, "parent" would be pytest itself; the legacy
    # module-level signal_handler below catches SIGTERM and `exit(1)`s,
    # which kills the entire test session during teardown.
    #
    # Pass parent=0 so that terminate_pid's `psutil.Process(0)` lookup
    # raises NoSuchProcess; terminate_pid swallows the exception and
    # receive_results breaks out of its loop normally. We do the same
    # shutdown work (job result drain + abort_list cleanup) regardless.
    results_thread = threading.Thread(
        target=webserver.receive_results,
        args=(
            0,
            app_exit,
            results_queue,
            abort_list,
            jobs_marked_done,
        ),
        name="cuopt-test-receive-results",
        daemon=True,
    )
    results_thread.start()

    # _test_watch_solvers is the pytest-safe shadow of
    # process_handler.watch_solvers. It drains abort_queue (so DELETE
    # /cuopt/request/{reqId} kills the running worker -- required by
    # test_job_abort.py and test_job_cache.py) but it does NOT auto-respawn
    # workers that die on their own. See the docstring on
    # _test_watch_solvers for why production's auto-heal behaviour is
    # actively harmful inside a pytest session sharing one GPU.
    watcher_thread = threading.Thread(
        target=_test_watch_solvers,
        args=(
            app_exit,
            job_queue,
            results_queue,
            abort_queue,
            abort_list,
            process_handler,
        ),
        name="cuopt-test-watch-solvers",
        daemon=True,
    )
    watcher_thread.start()

    # raise_server_exceptions=False so unhandled exceptions in route
    # handlers come back as 500 responses (matching uvicorn behaviour)
    # instead of bubbling into pytest as raises. The webserver registers
    # its own catchall exception_handler so this should rarely fire.
    test_client = TestClient(webserver.app, raise_server_exceptions=False)

    return {
        "app_exit": app_exit,
        "job_queue": job_queue,
        "abort_queue": abort_queue,
        "results_queue": results_queue,
        "jobs_marked_done": jobs_marked_done,
        "workers": workers,
        "results_thread": results_thread,
        "watcher_thread": watcher_thread,
        "test_client": test_client,
        "ExitJob": ExitJob,
        "Shutdown": Shutdown,
        "process_handler": process_handler,
    }


def _teardown_testclient(state):
    """Graceful shutdown so worker coverage fragments are actually flushed.

    Sequence:
      1. Set app_exit so both background loops (receive_results and
         watch_solvers) see it on their next iteration.
      2. Join watch_solvers FIRST, while every worker is still running.
         If we sent ExitJob before doing this, the worker would exit
         cleanly, watch_solvers would see "not process.is_alive()" and
         helpfully respawn it -- giving us a brand-new worker process to
         clean up after we thought we were done. Joining the watcher
         first removes that race.
      3. Inject ExitJob on job_queue, one per currently-registered worker
         (read from process_handler.get_solver_processes() so any worker
         that watch_solvers respawned mid-session is included). Workers
         break out of queue.get(), return from process_async_solve, and
         multiprocessing's atexit/coverage_finalize machinery flushes the
         per-pid .coverage fragment.
      4. Push Shutdown on results_queue so receive_results exits its
         while-True (otherwise the daemon thread silently logs nothing
         and the pytest process can't be joined cleanly).
      5. Workers get a generous join window (10s). If they don't exit
         gracefully we send SIGTERM. Production's process_async_solve
         normally masks SIGTERM with SIG_IGN, but _install_solver_coverage_shim
         has wrapped the worker so that SIG_IGN attempt is silently dropped
         and SIGTERM instead triggers a flush-and-exit handler that calls
         cov.save() and os._exit(0). SIGKILL is reserved for the rare
         case where the worker is wedged in an uninterruptible syscall.
    """
    app_exit = state["app_exit"]
    job_queue = state["job_queue"]
    results_queue = state["results_queue"]
    watcher_thread = state["watcher_thread"]
    results_thread = state["results_thread"]
    ExitJob = state["ExitJob"]
    Shutdown = state["Shutdown"]
    process_handler = state["process_handler"]

    app_exit.set()

    # watch_solvers polls abort_queue.get(timeout=0.5) and re-checks
    # app_exit between iterations. 5s gives it ~10 wakeups to notice.
    watcher_thread.join(timeout=5)

    # Use the *live* solver set, not the snapshot taken at fixture init,
    # so a worker that watch_solvers respawned during the session still
    # gets cleaned up.
    current_workers = [
        s.process for s in process_handler.get_solver_processes().values()
    ]
    for _ in current_workers:
        try:
            job_queue.put(ExitJob())
        except Exception:
            pass
    try:
        results_queue.put(Shutdown())
    except Exception:
        pass

    for w in current_workers:
        w.join(timeout=10)
        if w.is_alive():
            try:
                w.terminate()  # SIGTERM, lets coverage flush
            except Exception:
                pass
            w.join(timeout=3)
            if w.is_alive():
                try:
                    w.kill()  # SIGKILL last resort
                except Exception:
                    pass
                w.join(timeout=2)

    results_thread.join(timeout=5)


@pytest.fixture(scope="session")
def cuoptproc(request):
    """Session-scoped fixture that brings up the cuopt server.

    Two modes:

      * Default (CUOPT_TEST_TESTCLIENT unset): launches
        `python -m cuopt_server.cuopt_service` as a Popen subprocess on
        port 5555 and lets RequestClient drive it over HTTP. This is the
        legacy / production-shape path.

      * CUOPT_TEST_TESTCLIENT=1: hosts webserver.app in-process via
        starlette's TestClient, spawns solver workers as
        multiprocessing.Process children of pytest, and routes
        RequestClient through the TestClient. This is the coverage-
        friendly path (pytest-cov sees every webserver/handler line;
        workers write per-pid .coverage fragments).
    """
    global cuoptmain

    if _USE_TESTCLIENT:
        state = _setup_testclient_inprocess()
        _TC_STATE["test_client"] = state["test_client"]
        try:
            yield
        finally:
            _TC_STATE.pop("test_client", None)
            _teardown_testclient(state)
        return

    env = {
        **os.environ,
        "CUOPT_SERVER_IP": "0.0.0.0",
        "CUOPT_SERVER_PORT": "5555",
        "CUOPT_SERVER_LOG_LEVEL": "debug",
    }
    cuoptmain = Popen([python_path, server_script, server_module], env=env)
    spinup_wait()
    try:
        yield
    finally:
        cleanup_cuopt_process()


class RequestClient:
    """HTTP client used by every cuopt_server test.

    In legacy/Popen mode it wraps `requests` and talks to the server on
    self.url. In TestClient mode (CUOPT_TEST_TESTCLIENT=1) every method
    routes through the in-process starlette TestClient that the
    `cuoptproc` fixture installed in `_TC_STATE["test_client"]` -- giving
    pytest-cov visibility into webserver.py and the request handlers.

    Both backends expose the same response interface (.status_code,
    .json(), .content, .headers) so the existing tests don't care which
    one they're using.
    """

    def __init__(self, port=5555):
        self.ip = "127.0.0.1"
        self.port = port
        self.url = f"http://{self.ip}:{self.port}"
        # We deliberately do NOT resolve the TestClient here -- modules
        # do `client = RequestClient()` at import time, before the
        # `cuoptproc` fixture has run. We look up the TestClient lazily
        # on each call so the same RequestClient instance works for
        # both backends across the session.

    @property
    def _testclient(self):
        return _TC_STATE.get("test_client") if _USE_TESTCLIENT else None

    def poll_for_completion(self, reqId, delete=True):
        # Wait to complete. Polling ceiling is configurable via the
        # _POLL_MAX_SECONDS module constant (30s in TestClient mode, 600s
        # in legacy mode -- see the env-var comment near _POLL_MAX_SECONDS).
        cnt = 0
        headers = {"Accept": "application/json"}
        while True:
            res = self.get(f"/cuopt/solution/{reqId}", headers=headers)
            if "response" in res.json() or "error" in res.json():
                break
            time.sleep(1)
            cnt += 1
            if cnt == _POLL_MAX_SECONDS:
                break
        if delete:
            try:
                self.delete(
                    f"/cuopt/solution/{reqId}", headers=headers
                )
            except Exception:
                pass
        return res

    @staticmethod
    def _tc_kwargs(**kwargs):
        # starlette's TestClient is built on httpx, which (a) does NOT
        # accept `json=` on .get()/.delete() the way `requests` does and
        # (b) rejects unknown kwargs strictly. So we only forward the
        # arguments that were actually set, dropping any `None` placeholders
        # the callers pass for signature compatibility.
        return {k: v for k, v in kwargs.items() if v is not None}

    def post(
        self,
        endpoint,
        params=None,
        headers=None,
        json=None,
        data=None,
        block=True,
        delete=True,
    ):
        tc = self._testclient
        if tc is not None:
            res = tc.post(
                endpoint,
                **self._tc_kwargs(
                    params=params, headers=headers, json=json, data=data
                ),
            )
        else:
            res = requests.post(
                self.url + endpoint,
                params=params,
                headers=headers,
                json=json,
                data=data,
            )

        # cuopt/cuot is already blocking, don't ever poll
        if endpoint == "/cuopt/cuopt":
            block = False

        if (
            not block
            or res.status_code != 200
            or (headers and "cache" in headers and headers["cache"] is True)
        ):
            return res

        return self.poll_for_completion(res.json()["reqId"], delete)

    def get(self, endpoint, headers=None, json=None):
        tc = self._testclient
        if tc is not None:
            return tc.get(endpoint, **self._tc_kwargs(headers=headers))
        return requests.get(self.url + endpoint, headers=headers, json=json)

    def delete(self, endpoint, headers=None, json=None, params=None):
        tc = self._testclient
        if tc is not None:
            return tc.delete(
                endpoint,
                **self._tc_kwargs(params=params, headers=headers),
            )
        return requests.delete(
            self.url + endpoint, params=params, headers=headers, json=json
        )
