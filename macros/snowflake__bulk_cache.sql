{#- Bulk pre-warm of the constraint lookup cache.

    Upstream discovers current state with roughly four `SHOW ... IN TABLE` round
    trips per table, from a cache that starts empty every run. Whether replacing
    those with bulk reads is a win depends entirely on which read you replace,
    and the two halves behave completely differently.

    Measured on Snowflake, server-side (compile + execute):

      SHOW <kind> KEYS IN SCHEMA      0.26s   covers an entire schema
      SHOW <kind> KEYS IN TABLE       0.08s   covers one table
      SHOW <kind> KEYS IN DATABASE   19.30s   scans every schema in the database
      INFORMATION_SCHEMA.COLUMNS      5.57s   of which 3.49s is COMPILATION

    So schema-scoped constraint reads are a large win: 0.26s to cover a
    144-table schema against roughly 11.5s doing it a table at a time. Those are
    on by default.

    Column metadata is the opposite. `INFORMATION_SCHEMA` compilation scales with
    the number of objects in the whole database rather than with the schemas
    asked for, and the result is one row per column, which then has to be walked
    in Jinja at a measured ~0.8ms per row. A single schema can return 8,000+ rows,
    and a CI database holding every open branch's schemas is far worse. That read
    is off by default, and when it is enabled it aggregates server-side to one
    row per table.

    The bigger win on columns is not fetching them at all: see
    `table_columns_all_exist`, which skips the lookup entirely for a
    contract-enforced model, because the contract already guarantees what the
    lookup would check. -#}


{%- macro warm_lookup_cache(constraint_types, lookup_cache) -%}
    {{ return(adapter.dispatch('warm_lookup_cache', 'dbt_constraints')(constraint_types, lookup_cache)) }}
{%- endmacro -%}


{#- Adapters without a bulk metadata path keep upstream's per-table lookups. -#}
{%- macro default__warm_lookup_cache(constraint_types, lookup_cache) -%}
    {{ return(none) }}
{%- endmacro -%}


{%- macro snowflake__warm_lookup_cache(constraint_types, lookup_cache) -%}
    {%- if var('dbt_constraints_bulk_cache', "true")|string|lower != "true" -%}
        {{ return(none) }}
    {%- endif -%}

    {%- set targets = dbt_constraints.constraint_warm_targets(constraint_types) -%}
    {%- if targets | length == 0 -%}
        {{ return(none) }}
    {%- endif -%}

    {#- SHOW truncates at this many rows without signalling that it did, so a
        result at the cap cannot be trusted to be complete. -#}
    {%- set show_cap = 10000 -%}

    {#- Schema scope beats database scope until roughly seventy schemas, since
        0.26s per schema only overtakes a 19.3s database scan well past fifty.
        The default sits below the crossover so the common case is never the
        expensive one. -#}
    {%- set schema_threshold = var('dbt_constraints_bulk_schema_threshold', 50) | int -%}
    {%- set bulk_columns = var('dbt_constraints_bulk_columns', "false")|string|lower == "true" -%}

    {%- for database, schemas in targets.items() -%}
        {%- set state = namespace(truncated=false) -%}

        {%- set scopes = [] -%}
        {%- if schemas | length > 0 and schemas | length <= schema_threshold -%}
            {%- for schema in schemas -%}
                {%- do scopes.append("SCHEMA " ~ database ~ "." ~ schema) -%}
            {%- endfor -%}
        {%- else -%}
            {%- do scopes.append("DATABASE " ~ database) -%}
        {%- endif -%}

        {%- do log("dbt_constraints: warming " ~ database ~ " (" ~ schemas | length
                   ~ " schema(s) in scope) via " ~ scopes | length ~ " x 3 "
                   ~ ("schema-scoped" if schemas | length <= schema_threshold else "database-scoped")
                   ~ " constraint read(s)"
                   ~ (", plus aggregated column reads" if bulk_columns else ""), info=true) -%}

        {#- PRIMARY KEYS and UNIQUE KEYS both land in the unique_keys bucket,
            matching how upstream's per-table lookup treats them as
            interchangeable for satisfying a foreign key's parent.

            SHOW IMPORTED KEYS reports two tables per row, the parent and the
            child, so it has no bare schema_name or table_name column. Scoped
            IN TABLE upstream never had to choose between them; at bulk scope
            the child owns the constraint, so its fk_ columns are the ones to
            key on. -#}
        {%- for show_kind, bucket_name, name_col, col_col, schema_col, table_col in [
                ('PRIMARY KEYS',  'unique_keys',  'constraint_name', 'column_name',    'schema_name',    'table_name'),
                ('UNIQUE KEYS',   'unique_keys',  'constraint_name', 'column_name',    'schema_name',    'table_name'),
                ('IMPORTED KEYS', 'foreign_keys', 'fk_name',         'fk_column_name', 'fk_schema_name', 'fk_table_name') ] -%}

            {%- for scope in scopes -%}
                {%- set rows = run_query("SHOW " ~ show_kind ~ " IN " ~ scope) -%}

                {%- if rows.rows | length >= show_cap -%}
                    {%- do log("dbt_constraints: SHOW " ~ show_kind ~ " IN " ~ scope
                               ~ " returned " ~ rows.rows | length ~ " rows, at or above the " ~ show_cap
                               ~ " row cap, so it may be truncated. Falling back to per-table lookups for this database.", info=true) -%}
                    {%- set state.truncated = true -%}
                {%- elif rows.rows | length > 0
                         and (rows.rows[0][schema_col] is none or rows.rows[0][table_col] is none) -%}
                    {#- The keying column is absent or null, so Snowflake's SHOW
                        output has changed shape. Keying on it anyway would build
                        wrong cache entries and silently recreate constraints that
                        already exist, so refuse to warm instead. -#}
                    {%- do log("dbt_constraints: SHOW " ~ show_kind ~ " IN " ~ scope
                               ~ " did not return usable " ~ schema_col ~ "/" ~ table_col
                               ~ " columns. Falling back to per-table lookups for this database.", info=true) -%}
                    {%- set state.truncated = true -%}
                {%- else -%}
                    {%- set bucket = lookup_cache.bulk[bucket_name] -%}
                    {%- for row in rows.rows -%}
                        {%- set fqn = (database ~ '.' ~ row[schema_col] ~ '.' ~ row[table_col]) | upper -%}
                        {%- if fqn not in bucket -%}
                            {%- do bucket.update({fqn: {}}) -%}
                        {%- endif -%}
                        {%- set cname = row[name_col] -%}
                        {%- if cname not in bucket[fqn] -%}
                            {%- do bucket[fqn].update({cname: {"columns": [], "rely": row['rely']}}) -%}
                        {%- endif -%}
                        {%- do bucket[fqn][cname]["columns"].append(row[col_col]) -%}
                    {%- endfor -%}
                {%- endif -%}
            {%- endfor -%}
        {%- endfor -%}

        {#- Column metadata, off by default. Aggregated server-side to one row
            per table: the un-aggregated form returns one row per column, and at
            ~0.8ms per row in Jinja that dominates everything else the hook does. -#}
        {%- if bulk_columns and schemas | length > 0 -%}
            {%- set schema_csv = "'" ~ (schemas | map('upper') | join("','")) ~ "'" -%}
            {%- set col_query -%}
                select upper(table_schema) as "table_schema",
                       upper(table_name)   as "table_name",
                       array_agg(upper(column_name))                                          as "columns",
                       array_agg(case when is_nullable = 'NO' then upper(column_name) end)    as "not_null",
                       array_agg(case when data_type in ('VARIANT', 'ARRAY', 'OBJECT')
                                      then upper(column_name) end)                            as "semi_structured"
                from {{ database }}.information_schema.columns
                where upper(table_schema) in ( {{ schema_csv }} )
                group by 1, 2
            {%- endset -%}
            {%- set col_rows = run_query(col_query) -%}

            {%- for row in col_rows.rows -%}
                {%- set fqn = (database ~ '.' ~ row['table_schema'] ~ '.' ~ row['table_name']) | upper -%}
                {#- ARRAY_AGG drops nothing, so the conditional aggregates carry a
                    null per non-matching column; strip them rather than letting a
                    null land in a column-name list. -#}
                {%- do lookup_cache.bulk.columns.update({ fqn: fromjson(row['columns']) | reject('none') | list }) -%}
                {%- do lookup_cache.bulk.not_null.update({ fqn: fromjson(row['not_null']) | reject('none') | list }) -%}
                {%- do lookup_cache.bulk.semi_structured.update({ fqn: fromjson(row['semi_structured']) | reject('none') | list }) -%}
            {%- endfor -%}
        {%- endif -%}

        {%- if not state.truncated -%}
            {%- do lookup_cache.bulk.databases.append(database | upper) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- do log("dbt_constraints: bulk constraint cache warmed for "
               ~ lookup_cache.bulk.databases | length ~ " database(s)", info=true) -%}
{%- endmacro -%}
