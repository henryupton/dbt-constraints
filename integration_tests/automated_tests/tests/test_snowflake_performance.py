"""Snowflake performance rework: behaviour parity and idempotency.

The rework changes how constraint work is scheduled, never what it produces.
These tests hold that line by driving the same integration project twice, once
on the fast path and once with every optimisation disabled (which reduces the
package to upstream's behaviour), and comparing the resulting constraint state.

State is compared rather than emitted DDL on purpose. The charter is that the
outcome is identical; the statements used to reach it differing is the point.

Requires a live Snowflake connection. Set:

    DBT_TARGET=snowflake
    SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_ROLE
    SNOWFLAKE_WAREHOUSE / SNOWFLAKE_DATABASE / SNOWFLAKE_SCHEMA
    SNOWFLAKE_AUTHENTICATOR=externalbrowser   (or password / key-pair)
"""

import os
import subprocess

import pytest

PROJECT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "dbt-fusion")
)

FAST = ["--vars", "{dbt_constraints_bulk_cache: true, dbt_constraints_parallel: true}"]
SERIAL = ["--vars", "{dbt_constraints_bulk_cache: false, dbt_constraints_parallel: false}"]
# What actually ships: the bulk cache defaults off because it loses on a large
# warehouse, so parallel DDL alone is the configuration most runs will use.
DEFAULT = ["--vars", "{dbt_constraints_bulk_cache: false, dbt_constraints_parallel: true}"]

# Every log line the package emits immediately before issuing constraint DDL.
# Their absence is how a run proves it did no work.
DDL_MARKERS = (
    "Creating primary key",
    "Creating unique key",
    "Creating foreign key",
    "Creating not null constraint",
    "Updating constraint",
)

pytestmark = pytest.mark.skipif(
    os.environ.get("DBT_TARGET") != "snowflake",
    reason="Snowflake performance tests require DBT_TARGET=snowflake",
)


def run_dbt(args):
    result = subprocess.run(
        [os.path.expanduser("~/.local/bin/dbt")] + args + ["--profiles-dir", "."],
        cwd=PROJECT,
        capture_output=True,
        text=True,
    )
    return result.stdout + result.stderr


def constraint_state():
    """Every PK, UK and FK in the target database, as a comparable set."""
    out = run_dbt(["run-operation", "dump_constraint_state"])
    state = {
        line.strip()
        for line in out.splitlines()
        if line.strip().startswith("CONSTRAINT|")
    }
    assert state, f"no constraint state captured, run-operation output was:\n{out}"
    return state


def test_fast_path_leaves_the_same_state_as_the_serial_path():
    """The whole charter, expressed as one assertion."""
    run_dbt(["build", "--full-refresh"] + SERIAL)
    serial_state = constraint_state()

    run_dbt(["build", "--full-refresh"] + FAST)
    fast_state = constraint_state()

    assert fast_state == serial_state, (
        "fast path diverged from serial path\n"
        f"only in serial: {sorted(serial_state - fast_state)}\n"
        f"only in fast:   {sorted(fast_state - serial_state)}"
    )


def test_default_config_leaves_the_same_state_as_the_serial_path():
    """The shipped configuration, not just the two extremes.

    Bulk cache off and parallel DDL on is what most runs will use, and it was
    the one combination the original two arms never exercised.
    """
    run_dbt(["build", "--full-refresh"] + SERIAL)
    serial_state = constraint_state()

    run_dbt(["build", "--full-refresh"] + DEFAULT)
    default_state = constraint_state()

    assert default_state == serial_state, (
        "default config diverged from serial path\n"
        f"only in serial:  {sorted(serial_state - default_state)}\n"
        f"only in default: {sorted(default_state - serial_state)}"
    )


def test_steady_state_run_emits_no_ddl():
    """A run that rebuilds nothing must do no constraint work.

    This is what the bulk cache buys: it knows the current state of every
    constraint from a handful of queries, so it can tell there is nothing to do.
    `dbt test` is the right shape for this because it leaves the models alone,
    whereas a table-materialized rebuild legitimately drops and recreates
    constraints.
    """
    run_dbt(["build"] + FAST)
    second = run_dbt(["test"] + FAST)

    emitted = [marker for marker in DDL_MARKERS if marker in second]
    assert emitted == [], f"steady-state run still emitted DDL: {emitted}"


def test_bulk_cache_is_actually_used():
    """Guard against the fast path silently degrading to per-table lookups.

    Every fallback in the bulk warm is deliberately quiet, because falling back
    is correct behaviour. That makes it possible for the cache to stop working
    entirely without any test noticing, so assert it warmed at least one
    database.
    """
    out = run_dbt(["test"] + FAST)
    assert "bulk metadata cache warmed for" in out, (
        "bulk cache did not warm; the fast path degraded to per-table lookups\n" + out
    )
    assert "bulk metadata cache warmed for 0 database(s)" not in out
