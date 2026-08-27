{#- Batched parallel application of constraint DDL.

    Upstream issues one ALTER per constraint through run_query, on a single
    connection, strictly serially. Snowflake will run these concurrently if
    asked: a Snowflake Scripting block can submit statements as ASYNC children
    and wait on them with AWAIT ALL, giving roughly 25-way parallelism inside
    one session.

    Failure semantics match upstream. A failing child aborts the block and
    surfaces the real SQL error, and children that already succeeded stay
    committed, exactly as upstream leaves earlier constraints in place when a
    later one errors. The hook therefore remains idempotent and restartable. -#}


{#- Queue a DDL statement for batched parallel execution, or run it immediately
    when parallel application is off or the adapter is not Snowflake.

    Callers log their own "Creating ..." line before enqueueing, so the log
    reads in the same order as upstream regardless of when execution happens.

    `table_key` names the table the statement alters, and `exclusive` marks a
    statement that must not share a batch with another against the same table. -#}
{%- macro enqueue_ddl(lookup_cache, sql, label, table_key, exclusive=false) -%}
    {%- if var('dbt_constraints_parallel', "true")|string|lower != "true"
           or target.type != 'snowflake'
           or lookup_cache.get('ddl_queue') is none -%}
        {%- do run_query(sql) -%}
    {%- else -%}
        {%- do lookup_cache.ddl_queue.append({
                "sql": sql | trim | trim(';') | trim,
                "label": label,
                "table": table_key,
                "exclusive": exclusive }) -%}
    {%- endif -%}
{%- endmacro -%}


{#- Split a queue into batches of at most `batch_size`.

    Concurrent ALTER TABLE ... ADD CONSTRAINT against the same table is safe on
    Snowflake, verified by applying five to one table at once and confirming all
    five landed, so those batch freely. ALTER TABLE ... MODIFY ... SET NOT NULL
    is not proven safe under the same conditions, so statements marked exclusive
    are kept off a batch that already touches their table. -#}
{%- macro batch_ddl_queue(queue, batch_size) -%}
    {%- set batches = [] -%}
    {%- set state = namespace(current=[], seen=[]) -%}
    {%- for item in queue -%}
        {%- set conflict = item.exclusive and item.table in state.seen -%}
        {%- if state.current | length >= batch_size or conflict -%}
            {%- do batches.append(state.current) -%}
            {%- set state.current = [] -%}
            {%- set state.seen = [] -%}
        {%- endif -%}
        {%- do state.current.append(item) -%}
        {%- do state.seen.append(item.table) -%}
    {%- endfor -%}
    {%- if state.current | length > 0 -%}
        {%- do batches.append(state.current) -%}
    {%- endif -%}
    {{ return(batches) }}
{%- endmacro -%}


{#- Apply every queued statement, then leave the queue empty.

    The queue is cleared before execution rather than after, so an error part
    way through cannot cause the surviving statements to be replayed by a later
    flush. Each statement occupies exactly one line of the block body, and the
    statement-to-line mapping is logged first, because Snowflake identifies a
    failing child by its line number within the body. -#}
{%- macro flush_ddl_queue(lookup_cache) -%}
    {%- if lookup_cache.get('ddl_queue') is none -%}
        {{ return(none) }}
    {%- endif -%}
    {%- set queue = lookup_cache.ddl_queue -%}
    {%- if queue | length == 0 -%}
        {{ return(none) }}
    {%- endif -%}
    {%- do lookup_cache.update({"ddl_queue": []}) -%}

    {%- set batch_size = var('dbt_constraints_max_concurrency', 25) | int -%}
    {%- set batches = dbt_constraints.batch_ddl_queue(queue, batch_size) -%}
    {%- do log("Applying " ~ queue | length ~ " constraint statement(s) in "
               ~ batches | length ~ " parallel batch(es)", info=true) -%}

    {%- for batch in batches -%}
        {%- set lines = [] -%}
        {%- for item in batch -%}
            {%- do lines.append("  ASYNC (" ~ item.sql ~ ");") -%}
            {#- Body line 1 is the newline after $$, line 2 is BEGIN, so the
                first statement is body line 3. -#}
            {%- do log("  block line " ~ (loop.index + 2) ~ ": " ~ item.label, info=false) -%}
        {%- endfor -%}
        {%- set block -%}
EXECUTE IMMEDIATE $$
BEGIN
{{ lines | join('\n') }}
  AWAIT ALL;
  RETURN 'ok';
END;
$$
        {%- endset -%}
        {%- do run_query(block) -%}
    {%- endfor -%}
{%- endmacro -%}
