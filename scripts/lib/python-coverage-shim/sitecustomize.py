# SPDX-FileCopyrightText: Copyright (c) 2026 AMD
# SPDX-License-Identifier: Apache-2.0
"""
Subprocess coverage hook.

Python imports `sitecustomize` automatically at interpreter startup if it can
be found on sys.path. By placing this file in a directory we prepend to
PYTHONPATH (scripts/lib/python-coverage-shim/), we get a hook that runs in
EVERY Python subprocess spawned by the cuopt_server tests:

    pytest (parent)                        ← already instrumented by pytest-cov
      `-> subprocess.Popen("python -m cuopt_server.cuopt_service")
            `-> multiprocessing.Process(target=webserver.run_server)
            `-> multiprocessing.Process(target=solver.process_async_solve)

The pip-installed `coverage` package usually drops its own `coverage.pth` into
site-packages that does the same thing, but conda envs can be set up with
`ENABLE_USER_SITE=False` or otherwise skip .pth processing -- making the auto-
mechanism unreliable. This explicit shim is unconditionally activated by
PYTHONPATH and depends only on `coverage` being importable.

If the parent process already had its own `sitecustomize.py` (e.g. conda's),
we chain into it first so we don't shadow whatever it was doing.
"""
import os
import sys

# 1) Chain into any pre-existing sitecustomize (e.g. conda's) so we don't
#    silently break whatever path/encoding setup that file performs.
try:
    import importlib.util as _ilu

    _here = os.path.dirname(os.path.abspath(__file__))
    for _entry in sys.path:
        if not _entry:
            continue
        try:
            _absent = os.path.abspath(_entry)
        except Exception:
            continue
        if _absent == _here:
            continue
        _candidate = os.path.join(_entry, "sitecustomize.py")
        if not os.path.isfile(_candidate):
            continue
        try:
            _spec = _ilu.spec_from_file_location("_orig_sitecustomize", _candidate)
            if _spec and _spec.loader:
                _mod = _ilu.module_from_spec(_spec)
                _spec.loader.exec_module(_mod)  # type: ignore[union-attr]
        except Exception as _e:  # pragma: no cover - best-effort
            print(
                f"[coverage-shim] chained sitecustomize {_candidate} failed: {_e}",
                file=sys.stderr,
            )
        break
except Exception:  # pragma: no cover - never block interpreter startup
    pass

# 2) Start coverage if (and only if) the parent process asked us to.
#    `coverage.process_startup()` is a no-op when COVERAGE_PROCESS_START is
#    unset, so this shim is safe to leave on PYTHONPATH for all Python runs.
#
# We deliberately swallow the "no module named coverage" case silently:
# Conda's `source activate <env>` machinery spawns short-lived Python
# processes from the BASE conda env to run its own activation hooks, and
# that base env typically does NOT have `coverage` installed. Those
# subprocesses don't run any project code, so failing to start coverage in
# them is harmless -- but the unconditional warning print clutters CI logs
# (see "[coverage-shim] coverage.process_startup() failed: No module
# named 'coverage'" right after `>>> Activating conda env: cuopt_dev` in
# typical runs). Set ROCOPT_COVERAGE_SHIM_DEBUG=1 to re-enable verbose
# diagnostics when investigating subprocess-instrumentation issues.
if os.environ.get("COVERAGE_PROCESS_START"):
    _debug = bool(os.environ.get("ROCOPT_COVERAGE_SHIM_DEBUG"))
    _cov_started = False
    try:
        import coverage  # type: ignore[import-not-found]

        coverage.process_startup()
        _cov_started = True
    except ModuleNotFoundError as _e:  # pragma: no cover - best-effort
        if _debug:
            print(
                f"[coverage-shim] coverage not importable in this interpreter "
                f"({sys.executable}): {_e}",
                file=sys.stderr,
            )
    except Exception as _e:  # pragma: no cover - best-effort
        print(
            f"[coverage-shim] coverage.process_startup() failed: {_e}",
            file=sys.stderr,
        )

    # 3) Chain-wrap signal.signal so any handler the application later
    #    installs for SIGTERM/SIGINT flushes coverage BEFORE running.
    #
    # Motivation: cuopt_server's `cuopt_service.py` runs:
    #
    #      signal.signal(signal.SIGTERM, handle_exit)
    #      signal.signal(signal.SIGINT,  handle_exit)
    #
    # AFTER our process_startup() above. That overwrites coverage's own
    # SIGTERM handler installed by `sigterm = True` in .coveragerc, so when
    # the test cleanup `kill -TERM <pid>`s the subprocess, `handle_exit`
    # runs, SIGKILLs worker subprocesses via psutil, and the main process
    # eventually self-SIGKILLs (psutil.Process(os.getpid()).kill()) if any
    # multiprocessing-feeder thread is alive. SIGKILL bypasses atexit ->
    # coverage's accumulated tracing data never reaches disk -> webserver.py,
    # utils/solver.py, utils/mock_store.py, etc. report 0% in cuopt_server
    # despite being heavily exercised by the test suite.
    #
    # Our solution: monkey-patch signal.signal so any user-installed
    # SIGTERM/SIGINT handler is transparently wrapped with a "flush
    # coverage first, then run user code" shim. The user's handler still
    # runs with the same signature and semantics; the only addition is a
    # best-effort cov.save() call before it. This wrap is idempotent and
    # gated on ROCOPT_COVERAGE_SHIM_NO_SIGNAL_WRAP=1 in case it ever
    # interacts badly with a future library that introspects signal
    # handlers.
    if _cov_started and not os.environ.get("ROCOPT_COVERAGE_SHIM_NO_SIGNAL_WRAP"):
        try:
            import signal as _signal

            _signals_to_chain = {_signal.SIGTERM, _signal.SIGINT}
            _orig_signal_signal = _signal.signal
            _ATTR = "__rocopt_coverage_chained__"

            def _flush_then_call(_user_handler):
                def _chained(signum, frame):
                    try:
                        _cov = coverage.Coverage.current()
                        if _cov is not None:
                            # parallel=True / data_suffix is configured at
                            # start; save() writes a parallel-suffixed
                            # fragment so we don't clobber sibling data
                            # files written by other instrumented procs.
                            _cov.save()
                    except Exception as _save_err:  # pragma: no cover
                        if _debug:
                            print(
                                f"[coverage-shim] pre-signal cov.save() "
                                f"failed: {_save_err}",
                                file=sys.stderr,
                            )
                    # ALWAYS hand control to the user's handler -- never
                    # swallow signals on its behalf.
                    return _user_handler(signum, frame)

                # Mark so we don't double-wrap if user code does e.g.
                # signal.signal(SIGTERM, signal.getsignal(SIGTERM)).
                try:
                    setattr(_chained, _ATTR, True)
                except Exception:  # pragma: no cover - exotic handlers
                    pass
                return _chained

            def _wrapped_signal(signalnum, handler):
                # Pass-through for non-target signals, SIG_DFL/SIG_IGN/None,
                # non-callable handlers (defensive), and already-wrapped
                # handlers.
                if (
                    signalnum in _signals_to_chain
                    and handler not in (_signal.SIG_DFL, _signal.SIG_IGN, None)
                    and callable(handler)
                    and not getattr(handler, _ATTR, False)
                ):
                    handler = _flush_then_call(handler)
                return _orig_signal_signal(signalnum, handler)

            _signal.signal = _wrapped_signal  # type: ignore[assignment]
            if _debug:
                print(
                    "[coverage-shim] installed SIGTERM/SIGINT flush-on-signal "
                    f"wrapper in {sys.executable}",
                    file=sys.stderr,
                )
        except Exception as _e:  # pragma: no cover - best-effort
            if _debug:
                print(
                    f"[coverage-shim] failed to install signal wrapper: {_e}",
                    file=sys.stderr,
                )
