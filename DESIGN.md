# Design: performance rework of the Snowflake constraint path

Status: implemented and verified against Snowflake.
Date: 2026-08-27.
Fork point: `Snowflake-Labs/dbt_constraints` @ 1.0.9 (commit `205b5cf`, which is also upstream `main` HEAD).

## Why this fork exists

On a large production project, `dbt_constraints` reconciles roughly 250 PK/UK/FK constraints in
an `on-run-end` hook. In July 2026 that hook took about 87 minutes, which was half of the
nightly production build. Measurement at the time attributed 97.6% of it to foreign-key
`ALTER` statements on fact tables that had been rebuilt by `CREATE OR REPLACE`, each statement
costing about 20 seconds on full-size tables and all of them running serially on a single
connection.

That specific cause was addressed downstream by a `truncate_insert` materialization, which
keeps the table object (and therefore its constraints) across rebuilds so the hook finds them
already present and skips. What that fix does not address is the cost the hook pays even when
it creates nothing at all: several hundred serial metadata round-trips to discover current
state, and Jinja graph traversal that scales with the product of test count and graph size.

This fork targets that residual cost, plus the serial DDL that remains whenever constraints
genuinely do need creating.

## Charter

Latency only, behaviour identical. The fork must emit the same DDL, with the same `RELY` and
`NORELY` semantics, from the same test declarations, as upstream 1.0.9.

Explicit non-goals:

- No change to how constraints are declared. The `dbt_constraints.primary_key`,
  `.unique_key` and `.foreign_key` tests keep their names and arguments, so existing model
  YAML is untouched and reverting is a one-line change in `packages.yml`.
- No redesign of the application model. Applying constraints from per-model post-hooks would
  parallelise better, but `RELY` depends on a test result that does not exist until after the
  model builds, so it cannot be done behaviour-identically. Recorded here as considered and
  set aside.
- No changes to the BigQuery, Postgres, Oracle, Redshift or Vertica paths. They keep upstream
  behaviour untouched.
- Package name stays `dbt_constraints`, so `adapter.dispatch` and every existing test
  reference resolve unchanged.

Fusion compatibility is a hard requirement, not a nice-to-have: the target deployment runs dbt
Fusion 2.0. Upstream's Fusion accommodations (unwrapping `test_metadata.kwargs.arguments`,
and `get_results_group_by`) are load-bearing and must survive the rework.

## Baseline: where the time goes in 1.0.9

Three independent costs, in the order they bite:

1. **Metadata discovery, serial, roughly four round-trips per table.**
   `unique_constraint_exists` issues `SHOW UNIQUE KEYS IN TABLE` and
   `SHOW PRIMARY KEYS IN TABLE`; `foreign_key_exists` issues `SHOW IMPORTED KEYS IN TABLE`;
   `lookup_table_columns` issues `SHOW COLUMNS IN TABLE`. Each result is cached per table, but
   the cache starts empty every run, so a project with constraints on 180 tables pays roughly
   700 sequential round-trips before the first `ALTER` is issued. This cost is paid in full
   even on a run where every constraint already exists and nothing needs creating.

2. **DDL, serial, one statement per constraint.** Every create macro calls `run_query` on a
   single connection. Snowflake will happily run these concurrently; upstream never asks it to.

3. **Jinja traversal, O(tests x graph nodes).** `create_constraints_by_type` is invoked seven
   times, once per constraint type, and each invocation scans all of `graph.nodes.values()`.
   Within that scan, resolving a test's target tables scans the whole graph again per entry in
   `depends_on.nodes`, and `test_selected` scans it again per PK/UK test to find referencing
   foreign keys. Cheap under Fusion's Rust Jinja, expensive under dbt-core.

## Verified Snowflake behaviour

Every mechanism this design depends on was probed against a live Snowflake account on
2026-08-27 before the design was written. Results:

| Probe                                                     | Result                                                                             |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `SHOW {PRIMARY,UNIQUE,IMPORTED} KEYS IN DATABASE <db>`    | Supported, and carries the `rely` column, so it is shape-identical to the per-table form. A whole production database returned constraint metadata in the low hundreds of rows per type. |
| `<db>.INFORMATION_SCHEMA.COLUMNS` bulk read               | Tens of thousands of columns across a whole database in a single query, exposing `is_nullable` and a `data_type` sufficient to identify VARIANT, ARRAY and OBJECT columns. |
| `ASYNC (ALTER TABLE ... ADD CONSTRAINT ... RELY)`         | Accepted inside a Snowflake Scripting block. Constraint lands with `rely = true`.  |
| Failing `ASYNC` child under `AWAIT ALL`                   | Aborts the block and surfaces the real SQL compilation error plus the offending line number. |
| Sibling commit semantics                                  | Children that succeeded stay committed when a sibling fails. Partial progress is retained, so the hook stays idempotent and restartable. |
| Concurrency                                               | 50 children of 3 seconds each completed in 6 seconds (serial would be 150), so roughly 25-way. Over-submission queues rather than erroring. |

## Change 1: bulk metadata pre-warm

Add `snowflake__warm_lookup_cache(relations, lookup_cache)`, called once at the top of
`create_constraints`. For each distinct database across the relations that carry constraints,
it issues four queries and populates the whole cache:

```sql
SHOW PRIMARY KEYS IN DATABASE <db>;
SHOW UNIQUE KEYS IN DATABASE <db>;
SHOW IMPORTED KEYS IN DATABASE <db>;
SELECT table_schema, table_name, column_name, is_nullable, data_type
FROM <db>.information_schema.columns;
```

The existing `snowflake__unique_constraint_exists`, `snowflake__foreign_key_exists` and
`snowflake__lookup_table_columns` macros keep their signatures and their per-table fallback
path, but on a warm cache they now always hit it and never issue a `SHOW`. Several hundred
serial round-trips become four per database.

Two hazards get explicit handling.

**Cache keying.** Upstream keys `lookup_cache` by the dbt relation object. Bulk output gives
database, schema and table as strings, so the key becomes a normalised uppercase fully
qualified name. That is safe for unquoted identifiers, which is every identifier this project
produces, but it would silently mismatch a quoted or lowercase identifier. Any relation whose
identifier is quoted or is not already uppercase is excluded from the pre-warm and falls
through to upstream's per-table `SHOW`, which is correct if slower.

**Silent truncation.** Snowflake `SHOW` commands cap at 10,000 rows without signalling that
they did. If any bulk result returns exactly the cap, that database is treated as un-warmed
and every table in it falls back to per-table lookups. Observed volumes leave more than an
order of magnitude of headroom, so this is insurance rather than an expected path.

Controlled by `dbt_constraints_bulk_cache`, default `true`. Setting it `false` restores
upstream's per-table discovery exactly.

## Change 2: parallel DDL

The Snowflake create macros stop calling `run_query` directly. Instead they append
`{sql, constraint_name, log_line}` to a queue, and each phase flushes that queue through
`flush_constraint_ddl`, which emits:

```sql
EXECUTE IMMEDIATE $$
BEGIN
  ASYNC (<alter 1>);
  ASYNC (<alter 2>);
  ...
  AWAIT ALL;
  RETURN 'ok';
END;
$$
```

chunked at `dbt_constraints_max_concurrency`, default 25 to match measured throughput.

**Ordering is preserved by flushing per phase, not once at the end.** Upstream already
sequences the phases not_null, then primary_key, then unique_key, then foreign_key, precisely
because a foreign key requires its parent's PK or UK to exist first. Flushing at each phase
boundary inherits that guarantee without any new reasoning about dependencies. Within a phase
no constraint depends on another, so ordering inside a batch is free.

The optimistic cache update that upstream performs immediately after each `run_query` moves to
queue time. This matters: `snowflake__create_foreign_key` checks that the parent table has a
PK or UK before queueing, and that check must see PKs queued earlier in the run. Since the PK
phase flushes before the FK phase begins, the optimistic claim is always true by the time any
FK statement executes.

Controlled by `dbt_constraints_parallel`, default `true`. Setting it `false` restores
upstream's one-statement-per-`run_query` behaviour exactly.

## Change 3: graph indexing

Build three structures once, at the top of `create_constraints`, and pass them down:

- `nodes_by_id`, mapping `unique_id` to node, replacing the O(n) `selectattr` scan currently
  performed per entry in each test's `depends_on.nodes`.
- `constraint_tests`, the filtered and argument-normalised test list, built once instead of
  being rebuilt on each of the seven `create_constraints_by_type` calls.
- `fk_tests_by_parent`, mapping a parent model's `unique_id` to the foreign-key tests that
  reference it, replacing the full-graph scan inside `test_selected`.

Complexity falls from O(tests x nodes) to O(nodes + tests). No behaviour changes, because
these are lookups over the same data by a faster route.

## Considered and rejected: a LAST_ALTERED skip filter

The idea was to query `information_schema.tables` for `last_altered` and skip constraint
reconciliation for tables this run did not touch. It is not worth building, for two reasons.

It is redundant. The bulk cache from Change 1 already returns exact current state for every
constraint, namely whether it exists and what its `rely` value is, and upstream's existing
logic already emits no DDL when that state matches the desired state. `last_altered` would be
a less precise proxy for a decision the cache answers exactly.

It is also a poor proxy. Snowflake bumps `last_altered` on DML, so every incremental model
that merged a single row looks changed, which is most of the project. The filter would skip
almost nothing while adding a query and a correctness risk.

What is worth keeping is the guarantee, expressed as a test rather than a feature: a second
consecutive run against unchanged data must emit zero DDL. That assertion goes in the
integration suite.

## Configuration surface

Three new variables, all additive, all defaulting to the fast path:

| Variable                          | Default | Effect when changed                                          |
| --------------------------------- | ------- | ------------------------------------------------------------ |
| `dbt_constraints_bulk_cache`      | `true`  | `false` restores upstream per-table `SHOW` discovery.        |
| `dbt_constraints_parallel`        | `true`  | `false` restores upstream serial `run_query` per statement.  |
| `dbt_constraints_max_concurrency` | `25`    | Batch size for `ASYNC` children per `EXECUTE IMMEDIATE` block. |

Setting `dbt_constraints_bulk_cache` and `dbt_constraints_parallel` both to `false` should
reduce the fork to upstream behaviour, which makes them the first diagnostic step for any
suspected regression, and gives the parity harness below a control arm.

## Error handling

A failing `ASYNC` child aborts its block and propagates a real Snowflake error, so a broken
constraint fails the hook exactly as it does upstream. Children that already succeeded stay
committed, which also matches upstream, where an error leaves previously created constraints
in place.

Reporting improves on upstream. Batching means the per-statement log lines upstream prints
before each `run_query` no longer interleave with execution, so instead the flush logs the
whole batch up front and, on failure, maps the line number Snowflake reports back to the
constraint name at that index and names the culprit. Upstream cannot do this once statements
are batched, and today relies on the reader correlating the last log line printed.

Fallbacks are layered so that no failure mode is fatal: a truncated or unavailable bulk read
degrades that database to per-table lookups, and `dbt_constraints_parallel: false` degrades
DDL to serial. Both degradations land on upstream's code path, which is already proven.

## Testing

**DDL parity harness.** The charter is behaviour identical, so it gets verified rather than
asserted. Run upstream 1.0.9 and this fork against the same integration project, capture every
DDL statement each emits, and assert the two sets are equal ignoring order. This is the
primary correctness gate and it must pass before the fork is pinned anywhere.

**Idempotency.** A second consecutive run against unchanged data emits zero DDL. This is the
residue of the rejected `LAST_ALTERED` filter and the clearest signal that the bulk cache
reflects reality.

**RELY reconciliation.** Reproduce upstream's existing flip coverage: a passing test sets
`RELY`, a failing test sets `NORELY`, and a subsequent pass restores `RELY`, on a table whose
constraint persists across runs. This behaviour is the reason the adopting project pins 1.0.9
rather than 1.0.8, so regressing it would be worse than the performance problem being solved.

**Fallback arms.** The suite runs with `bulk_cache: false` and with `parallel: false` as well
as with both on, since those paths are the supported escape hatches and an untested escape
hatch is not one.

**Inherited suites.** Upstream's dbt-core and dbt-fusion integration tests come with the fork
and both must stay green. The Fusion arm is not optional, because that is what production runs.

## The bulk metadata cache was wrong, and is now off by default

Recorded after measuring against a real warehouse rather than the integration
project. This is the most important thing on this page.

**The premise was false.** This design asserts that upstream's per-table metadata
discovery is expensive, and estimated "several hundred serial round-trips" as a
dominant cost. Measured on Snowflake, a per-table `SHOW` costs about **0.09s**,
so the 721 of them a full production run issues total roughly **61 seconds**. The
bulk equivalent, on the same project and the same run shape, cost **268 seconds**
across 16 queries.

| | queries | total |
| --- | --- | --- |
| upstream `SHOW ... KEYS IN TABLE` | 480 | 43.8s (0.09s avg) |
| upstream `SHOW COLUMNS IN TABLE` | 241 | 16.8s (0.07s avg) |
| **upstream total** | **721** | **~61s** |
| fork `SHOW ... IN DATABASE` | 3 | 57.9s (19.3s avg) |
| fork `SHOW ... IN SCHEMA` | 3 | 8.6s (2.87s avg) |
| fork `INFORMATION_SCHEMA.COLUMNS` | 10 | ~200s |
| **fork total** | **16** | **~268s** |

Two things drive it. `INFORMATION_SCHEMA.COLUMNS` scales with the number of
objects in the entire database rather than with the schemas asked for, and it
dominates. And `SHOW ... IN DATABASE` averaged 19.3s against a 1300-table
database, against 0.09s for the targeted per-table form.

Trading many cheap targeted reads for a few expensive broad ones is only a win
when the per-read overhead dominates. At 0.09s per round trip it does not. The
earlier measurements that motivated this design were taken against a small
sandbox schema and a 33-table integration project, and did not generalise.

`dbt_constraints_bulk_cache` therefore **defaults to `false`**. The machinery is
kept, proven correct and covered by tests, because it does win where the target
database is small or isolated. It is no longer claimed as a general improvement.

What survives as an unconditional win is the parallel DDL and the graph
indexing, neither of which depends on warehouse size, plus the two upstream
not-null bugs fixed below.

## What implementation changed about this design

Recorded after the fact. Four things the design did not anticipate, all found by
running it rather than by reasoning about it.

**Bulk reads have to be scoped by schema, not always by database.** The design
assumed `SHOW ... IN DATABASE` was strictly better. It is not: it scans every
schema in the database including ones the project never touches. Measured at 15s
against a 973-table shared database versus 0.5s for the single schema actually
needed. Shipping database-scope-always would have made the hook *slower* than
upstream on small projects. The fork now warms per schema at or below
`dbt_constraints_bulk_schema_threshold` schemas and per database above it,
because a large warehouse needing fourteen schemas is the case where database
scope wins again.

**`SHOW IMPORTED KEYS` has no bare `schema_name` or `table_name` column.** It
reports two tables per row, the parent and the child, as `pk_` and `fk_` prefixed
pairs. Scoped `IN TABLE` upstream never had to choose between them. At bulk scope
the child owns the constraint, so the `fk_` columns are the ones to key on.
Getting this wrong produced a cache that silently missed every existing foreign
key and tried to recreate them. The bulk warm now refuses to warm a database
whose keying columns come back null, so this class of mistake fails loudly.

**Concurrent DDL against the same table is safe for `ADD CONSTRAINT`.** Verified
by applying five foreign keys to one table concurrently and confirming all five
landed, reproducibly. This matters because the production shape is fact tables
carrying four to eight foreign keys each, which all land in the same phase.
`MODIFY ... SET NOT NULL` was not verified safe under the same conditions, so
those statements are marked exclusive and kept off a batch already touching their
table.

**Two upstream not-null bugs were re-issuing every statement on every run.**
`create_not_null` compared raw test parameters against an uppercased cache so its
"already not null" check never matched, and the `SHOW COLUMNS` fallback tested
nullability against `'false'` when Snowflake reports `'NOT_NULL'`. Both are fixed
here. They caused redundant work, never wrong results, so the end state is
unchanged. Without the fix the idempotency guarantee below was unreachable.

## Rollout

1. Implement against the fork's own integration project and get the parity harness green.
2. Pin the fork by git revision in the adopting project's `packages.yml`, replacing the
   `Snowflake-Labs/dbt_constraints` hub entry, and confirm a full parse and build under
   Fusion 2.0.
3. Compare a production daily run against the current baseline for wall time and, more
   importantly, for an identical set of constraints at identical `rely` values afterwards.
4. Revert is a one-line change back to the hub package, since no model YAML changed.

Upstreaming any of this as a pull request to `Snowflake-Labs/dbt_constraints` stays optional
and is not a goal of the first pass.
