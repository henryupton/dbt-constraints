{#- Bulk pre-warm of the constraint lookup cache.

    Upstream discovers current constraint state with roughly four round trips per
    table: SHOW UNIQUE KEYS, SHOW PRIMARY KEYS, SHOW IMPORTED KEYS and
    SHOW COLUMNS, each scoped IN TABLE and each cached only after the fact. The
    cache starts empty every run, so a project with constraints on a few hundred
    tables pays that cost serially before the first ALTER is issued, and pays it
    in full even on a run where nothing needs creating.

    All three SHOW commands also accept IN DATABASE, returning the same columns
    including `rely`, and column metadata is available in bulk from
    INFORMATION_SCHEMA. So the whole cache can be filled with four queries per
    database instead. -#}


{%- macro warm_lookup_cache(constraint_types, lookup_cache) -%}
    {{ return(adapter.dispatch('warm_lookup_cache', 'dbt_constraints')(constraint_types, lookup_cache)) }}
{%- endmacro -%}


{#- Adapters without a bulk metadata path keep upstream's per-table lookups. -#}
{%- macro default__warm_lookup_cache(constraint_types, lookup_cache) -%}
    {{ return(none) }}
{%- endmacro -%}


{#- Fill `lookup_cache.bulk` for every database in `targets`, a dict of
    {database: [schema, ...]}. A database is only recorded in
    `lookup_cache.bulk.databases` when every one of its constraint reads
    completed intact; anything else leaves it absent, and the per-table lookups
    then behave exactly as upstream for every table in it. -#}
{%- macro snowflake__warm_lookup_cache(constraint_types, lookup_cache) -%}
    {%- if var('dbt_constraints_bulk_cache', "true")|string|lower != "true" -%}
        {{ return(none) }}
    {%- endif -%}

    {%- set targets = dbt_constraints.constraint_warm_targets(constraint_types) -%}

    {#- SHOW truncates at this many rows without signalling that it did, so a
        result at the cap cannot be trusted to be complete. -#}
    {%- set show_cap = 10000 -%}

    {#- SHOW ... IN DATABASE scans every schema in the database, including ones
        this project never touches, so on a large shared database it can cost
        more than the per-table lookups it replaces. SHOW ... IN SCHEMA is far
        cheaper but costs one query per schema. Measured on Snowflake:
        IN SCHEMA runs in 0.5s against a small schema and 3.9s against a large
        one, while IN DATABASE runs in 15s against a 973-table database. So
        schema scope wins until the schema count passes roughly five, and
        database scope wins after that. -#}
    {%- set schema_threshold = var('dbt_constraints_bulk_schema_threshold', 5) | int -%}

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

        {#- A database-scoped warm reads every schema in the database, including
            ones this project never touches, so when one is chosen it should be
            visible without reading the code. This is the first line to check if
            the warm is slow. -#}
        {%- do log("dbt_constraints: warming " ~ database ~ " (" ~ schemas | length
                   ~ " schema(s) in scope) via " ~ scopes | length ~ " x 3 "
                   ~ ("schema-scoped" if schemas | length <= schema_threshold else "database-scoped")
                   ~ " metadata read(s)", info=true) -%}

        {#- Constraint metadata. PRIMARY KEYS and UNIQUE KEYS both land in the
            unique_keys bucket, matching how upstream's per-table lookup treats
            them as interchangeable for satisfying a foreign key's parent.

            SHOW IMPORTED KEYS reports two tables per row, the parent and the
            child, so it has no bare schema_name or table_name column. Scoped
            IN TABLE upstream never had to choose between them; at database
            scope the child table is the one that owns the constraint, so its
            fk_ prefixed columns are the ones to key on. -#}
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
                    {#- The column this bulk read keys on is absent or null, which
                        means Snowflake's SHOW output has changed shape. Keying on it
                        anyway would build wrong cache entries and silently recreate
                        constraints that already exist, so refuse to warm instead. -#}
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

        {#- Column metadata. INFORMATION_SCHEMA has no row cap, and is filtered
            down to the schemas that actually carry constraint tests so the
            result stays proportional to the work rather than to the database. -#}
        {%- if schemas | length > 0 -%}
            {%- set schema_csv = "'" ~ (schemas | map('upper') | join("','")) ~ "'" -%}
            {%- set col_query -%}
                select upper(table_schema) as "table_schema",
                       upper(table_name)   as "table_name",
                       upper(column_name)  as "column_name",
                       is_nullable         as "is_nullable",
                       data_type           as "data_type"
                from {{ database }}.information_schema.columns
                where upper(table_schema) in ( {{ schema_csv }} )
            {%- endset -%}
            {%- set col_rows = run_query(col_query) -%}

            {%- for row in col_rows.rows -%}
                {%- set fqn = (database ~ '.' ~ row['table_schema'] ~ '.' ~ row['table_name']) | upper -%}
                {%- if fqn not in lookup_cache.bulk.columns -%}
                    {%- do lookup_cache.bulk.columns.update({fqn: []}) -%}
                    {%- do lookup_cache.bulk.not_null.update({fqn: []}) -%}
                    {%- do lookup_cache.bulk.semi_structured.update({fqn: []}) -%}
                {%- endif -%}
                {%- do lookup_cache.bulk.columns[fqn].append(row['column_name']) -%}
                {%- if row['is_nullable'] == 'NO' -%}
                    {%- do lookup_cache.bulk.not_null[fqn].append(row['column_name']) -%}
                {%- endif -%}
                {#- Snowflake rejects NOT NULL on semi-structured columns, so
                    upstream skips them; identify them the same way here. -#}
                {%- if row['data_type'] in ('VARIANT', 'ARRAY', 'OBJECT') -%}
                    {%- do lookup_cache.bulk.semi_structured[fqn].append(row['column_name']) -%}
                {%- endif -%}
            {%- endfor -%}
        {%- endif -%}

        {%- if not state.truncated -%}
            {%- do lookup_cache.bulk.databases.append(database | upper) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- do log("dbt_constraints: bulk metadata cache warmed for "
               ~ lookup_cache.bulk.databases | length ~ " database(s), "
               ~ lookup_cache.bulk.columns | length ~ " table(s)", info=true) -%}
{%- endmacro -%}
