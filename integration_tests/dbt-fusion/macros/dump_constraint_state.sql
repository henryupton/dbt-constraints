{#- Emit every PK, UK and FK in the target database in a stable, comparable
    form, one line per constraint column.

    Used by the performance tests to assert that the fast path leaves the
    database in exactly the same state as the serial path. Comparing state
    rather than emitted DDL is deliberate: the charter is that the outcome is
    identical, and the whole point of the rework is that the statements needed
    to reach that outcome differ. -#}
{%- macro dump_constraint_state() -%}
    {%- if execute -%}
        {%- set lines = [] -%}
        {%- for kind, name_col, col_col, schema_col, table_col in [
                ('PRIMARY KEYS',  'constraint_name', 'column_name',    'schema_name',    'table_name'),
                ('UNIQUE KEYS',   'constraint_name', 'column_name',    'schema_name',    'table_name'),
                ('IMPORTED KEYS', 'fk_name',         'fk_column_name', 'fk_schema_name', 'fk_table_name') ] -%}
            {%- set rows = run_query("SHOW " ~ kind ~ " IN DATABASE " ~ target.database) -%}
            {%- for row in rows.rows -%}
                {%- do lines.append(
                    "CONSTRAINT|" ~ kind
                    ~ "|" ~ row[schema_col] ~ "|" ~ row[table_col]
                    ~ "|" ~ row[name_col]   ~ "|" ~ row[col_col]
                    ~ "|" ~ row['rely']) -%}
            {%- endfor -%}
        {%- endfor -%}
        {%- for line in lines | sort -%}
            {%- do log(line, info=true) -%}
        {%- endfor -%}
    {%- endif -%}
{%- endmacro -%}
