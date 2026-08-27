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


{%- macro warm_lookup_cache(targets, lookup_cache) -%}
    {{ return(adapter.dispatch('warm_lookup_cache', 'dbt_constraints')(targets, lookup_cache)) }}
{%- endmacro -%}


{#- Adapters without a bulk metadata path keep upstream's per-table lookups. -#}
{%- macro default__warm_lookup_cache(targets, lookup_cache) -%}
    {{ return(none) }}
{%- endmacro -%}


{#- Fill `lookup_cache.bulk` for every database in `targets`, a dict of
    {database: [schema, ...]}. A database is only recorded in
    `lookup_cache.bulk.databases` when every one of its constraint reads
    completed intact; anything else leaves it absent, and the per-table lookups
    then behave exactly as upstream for every table in it. -#}
{%- macro snowflake__warm_lookup_cache(targets, lookup_cache) -%}
    {%- if var('dbt_constraints_bulk_cache', "true")|string|lower != "true" -%}
        {{ return(none) }}
    {%- endif -%}

    {#- SHOW truncates at this many rows without signalling that it did, so a
        result at the cap cannot be trusted to be complete. -#}
    {%- set show_cap = 10000 -%}

    {%- for database, schemas in targets.items() -%}
        {%- set state = namespace(truncated=false) -%}

        {#- Constraint metadata. PRIMARY KEYS and UNIQUE KEYS both land in the
            unique_keys bucket, matching how upstream's per-table lookup treats
            them as interchangeable for satisfying a foreign key's parent. -#}
        {%- for show_kind, bucket_name, name_col, col_col in [
                ('PRIMARY KEYS',  'unique_keys',  'constraint_name', 'column_name'),
                ('UNIQUE KEYS',   'unique_keys',  'constraint_name', 'column_name'),
                ('IMPORTED KEYS', 'foreign_keys', 'fk_name',         'fk_column_name') ] -%}

            {%- set rows = run_query("SHOW " ~ show_kind ~ " IN DATABASE " ~ database) -%}

            {%- if rows.rows | length >= show_cap -%}
                {%- do log("dbt_constraints: SHOW " ~ show_kind ~ " IN DATABASE " ~ database
                           ~ " returned " ~ rows.rows | length ~ " rows, at or above the " ~ show_cap
                           ~ " row cap, so it may be truncated. Falling back to per-table lookups for this database.", info=true) -%}
                {%- set state.truncated = true -%}
            {%- else -%}
                {%- set bucket = lookup_cache.bulk[bucket_name] -%}
                {%- for row in rows.rows -%}
                    {%- set fqn = (database ~ '.' ~ row['schema_name'] ~ '.' ~ row['table_name']) | upper -%}
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
