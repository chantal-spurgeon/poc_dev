"""
streamlit_timing.py: drop-in timing/error logging for Streamlit apps running on
a Snowpark Container Services compute pool.

Each line is written to stdout as:  APPTIMING {json}
Snowflake collects container stdout into the event table, where
v_app_timing in compute_pool_monitoring.sql parses it.

Logging to stdout only works if the service spec has logging enabled
(the default) and the account has an event table set.

Usage (top of your Streamlit script):

    import streamlit as st
    from streamlit_timing import timed_run, timed

    APP = "sales_dashboard"

    @timed("load_sales")                  # optional: time individual steps
    def load_sales(session):
        return session.sql("select ...").to_pandas()

    with timed_run(APP):                  # wraps the whole script run
        st.title("Sales")
        df = load_sales(session)
        st.dataframe(df)
"""
import contextlib
import functools
import json
import time

import streamlit as st

# Module-level state lives for the life of the container's Python process,
# because Python caches imported modules across Streamlit reruns.
_PROCESS_START = time.time()
_runs_in_process = 0


def _emit(event: dict) -> None:
    # One line, flushed immediately so it reaches the event table promptly.
    print("APPTIMING " + json.dumps(event, default=str), flush=True)


@contextlib.contextmanager
def timed_run(app: str):
    """Wrap a full script run. Records duration, status, and cold-start flags."""
    global _runs_in_process

    first_in_process = _runs_in_process == 0
    _runs_in_process += 1
    first_in_session = "_apptiming_seen" not in st.session_state
    st.session_state["_apptiming_seen"] = True

    start = time.perf_counter()
    status = "ok"
    try:
        yield
    except BaseException as exc:  # includes Streamlit's rerun/stop control flow
        # st.rerun() and st.stop() raise internal exceptions that are not
        # failures; only count real errors.
        name = type(exc).__name__
        if name not in ("RerunException", "StopException"):
            status = "error"
            _emit({
                "evt": "app_error",
                "app": app,
                "error_type": name,
                "message": str(exc)[:300],
            })
        raise
    finally:
        _emit({
            "evt": "app_run",
            "app": app,
            "status": status,
            "run_ms": round((time.perf_counter() - start) * 1000, 1),
            "first_in_session": first_in_session,
            "first_in_process": first_in_process,
            "process_age_s": round(time.time() - _PROCESS_START, 1),
        })


def timed(label: str, app: str = ""):
    """Decorator to time one step (a query, a transform). Shows up with evt=step."""
    def wrap(fn):
        @functools.wraps(fn)
        def inner(*args, **kwargs):
            start = time.perf_counter()
            status = "ok"
            try:
                return fn(*args, **kwargs)
            except Exception:
                status = "error"
                raise
            finally:
                _emit({
                    "evt": "step",
                    "app": app,
                    "label": label,
                    "status": status,
                    "run_ms": round((time.perf_counter() - start) * 1000, 1),
                })
        return inner
    return wrap
