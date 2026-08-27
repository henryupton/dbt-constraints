{#- Define three tests for PK, UK, and FK that can be overridden by DB implementations.
    These tests have overloaded parameter names to be as flexible as possible. -#}

{%- test primary_key(model,
        column_name=none, column_names=[],
        quote_columns=false, constraint_name=none) -%}

    {%- if column_names|count == 0 and column_name -%}
        {%- do column_names.append(column_name) -%}
    {%- endif -%}

    {{ return(adapter.dispatch('test_primary_key', 'dbt_constraints')(model, column_names, quote_columns)) }}

{%- endtest -%}


{%- test unique_key(model,
        column_name=none, column_names=[],
        quote_columns=false, constraint_name=none) -%}

    {%- if column_names|count == 0 and column_name -%}
        {%- do column_names.append(column_name) -%}
    {%- endif -%}

    {{ return(adapter.dispatch('test_unique_key', 'dbt_constraints')(model, column_names, quote_columns)) }}

{%- endtest -%}


{%- test foreign_key(model,
        column_name=none, fk_column_name=none, fk_column_names=[],
        pk_table_name=none, to=none,
        pk_column_name=none, pk_column_names=[], field=none,
        quote_columns=false, constraint_name=none) -%}

    {%- if pk_column_names|count == 0 and (pk_column_name or field) -%}
        {%- do pk_column_names.append( (pk_column_name or field) ) -%}
    {%- endif -%}
    {%- if fk_column_names|count == 0 and (fk_column_name or column_name) -%}
        {%- do fk_column_names.append( (fk_column_name or column_name) ) -%}
    {%- endif -%}
    {%- set pk_table_name = pk_table_name or to -%}

    {{ return(adapter.dispatch('test_foreign_key', 'dbt_constraints')(model, fk_column_names, pk_table_name, pk_column_names, quote_columns)) }}

{%- endtest -%}




{#- Define three create macros for PK, UK, and FK that can be overridden by DB implementations -#}

{%- macro create_primary_key(table_model, column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause) -%}
    {{ return(adapter.dispatch('create_primary_key', 'dbt_constraints')(table_model, column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause)) }}
{%- endmacro -%}


{%- macro create_unique_key(table_model, column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause) -%}
    {{ return(adapter.dispatch('create_unique_key', 'dbt_constraints')(table_model, column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause)) }}
{%- endmacro -%}


{%- macro create_foreign_key(pk_table_relation, pk_column_names, fk_table_relation, fk_column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause) -%}
    {{ return(adapter.dispatch('create_foreign_key', 'dbt_constraints')(pk_table_relation, pk_column_names, fk_table_relation, fk_column_names, verify_permissions, quote_columns, constraint_name, lookup_cache, rely_clause)) }}
{%- endmacro -%}


{%- macro create_not_null(table_relation, column_names, verify_permissions, quote_columns, lookup_cache, rely_clause) -%}
    {{ return(adapter.dispatch('create_not_null', 'dbt_constraints')(table_relation, column_names, verify_permissions, quote_columns, lookup_cache, rely_clause)) }}
{%- endmacro -%}


{#- Define two macros for detecting if PK, UK, and FK exist that can be overridden by DB implementations -#}

{%- macro unique_constraint_exists(table_relation, column_names, lookup_cache) -%}
    {{ return(adapter.dispatch('unique_constraint_exists', 'dbt_constraints')(table_relation, column_names, lookup_cache) ) }}
{%- endmacro -%}

{%- macro foreign_key_exists(table_relation, column_names, lookup_cache) -%}
    {{ return(adapter.dispatch('foreign_key_exists', 'dbt_constraints')(table_relation, column_names, lookup_cache)) }}
{%- endmacro -%}


{#- Define two macros for detecting if we have sufficient privileges that can be overridden by DB implementations -#}

{%- macro have_references_priv(table_relation, verify_permissions, lookup_cache) -%}
    {{ return(adapter.dispatch('have_references_priv', 'dbt_constraints')(table_relation, verify_permissions, lookup_cache) ) }}
{%- endmacro -%}

{%- macro have_ownership_priv(table_relation, verify_permissions, lookup_cache) -%}
    {{ return(adapter.dispatch('have_ownership_priv', 'dbt_constraints')(table_relation, verify_permissions, lookup_cache)) }}
{%- endmacro -%}


{#- Define macro for whether a DB implementation has implemented logic for RELY and NORELY constraints -#}

{%- macro adapter_supports_rely_norely(test_name) -%}
    {{ return(adapter.dispatch('adapter_supports_rely_norely', 'dbt_constraints')(test_name)) }}
{%- endmacro -%}

{#- By default, we assume DB implementations have NOT implemented logic for RELY and NORELY constraints -#}
{%- macro default__adapter_supports_rely_norely(test_name) -%}
    {{ return(false) }}
{%- endmacro -%}




{#- Override dbt's truncate_relation macro to allow us to create adapter specific versions that drop constraints -#}

{% macro truncate_relation(relation) -%}
  {{ return(adapter.dispatch('truncate_relation')(relation)) }}
{% endmacro %}

{#- Override dbt's drop_relation macro to allow us to create adapter specific versions that drop constraints -#}

{% macro drop_relation(relation) -%}
  {{ return(adapter.dispatch('drop_relation')(relation)) }}
{% endmacro %}



{#- This macro should be added to on-run-end to create constraints
    after all the models and tests have completed. You can pass a
    list of the tests that you want considered for constraints and
    a flag for whether columns should be quoted. The first macro
    primarily controls the order that constraints are created. -#}
{%- macro create_constraints(
        constraint_types=[
            'primary_key',
            'unique_key',
            'unique_combination_of_columns',
            'unique',
            'foreign_key',
            'relationships',
            'not_null'],
        quote_columns=false) -%}
    {%- if execute and var('dbt_constraints_enabled', "false")|string|lower == "true" and results -%}
        {%- do log("Running dbt Constraints", info=true) -%}

        {#- `lookup_cache` doubles as the per-run context. Alongside upstream's
            metadata buckets it now carries the pending DDL queue, the bulk
            metadata read, and the graph indexes, so no macro signature has to
            change to reach them. -#}
        {%- set lookup_cache = {
            "table_columns": { },
            "table_privileges": { },
            "unique_keys": { },
            "not_null_col": { },
            "semi_structured_col": { },
            "foreign_keys": { },
            "ddl_queue": [ ],
            "bulk": {
                "unique_keys": { },
                "foreign_keys": { },
                "columns": { },
                "not_null": { },
                "semi_structured": { },
                "databases": [ ] } } -%}

        {#- Adapters with no bulk path resolve this to a no-op, so the graph walk
            that computes the warm targets happens inside the Snowflake
            implementation rather than here, where every adapter would pay it. -#}
        {%- do dbt_constraints.warm_lookup_cache(constraint_types, lookup_cache) -%}

        {#- Each phase flushes before the next begins. That ordering is what
            foreign keys depend on: upstream sequences not_null, then PK, then
            UK, then FK precisely so a foreign key's parent already carries a
            PK or UK by the time the FK is applied. Flushing at the phase
            boundary inherits that guarantee without any new reasoning, and a
            flush with an empty queue returns immediately. -#}
        {%- if 'not_null' in constraint_types and var('dbt_constraints_nn_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['not_null'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'primary_key' in constraint_types and var('dbt_constraints_pk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['primary_key'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'unique_key' in constraint_types and var('dbt_constraints_uk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['unique_key'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'unique_combination_of_columns' in constraint_types and var('dbt_constraints_uk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['unique_combination_of_columns'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'unique' in constraint_types and var('dbt_constraints_uk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['unique'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'foreign_key' in constraint_types and var('dbt_constraints_fk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['foreign_key'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}
        {%- if 'relationships' in constraint_types and var('dbt_constraints_fk_enabled', "true")|string|lower == "true" -%}
            {%- do dbt_constraints.create_constraints_by_type(['relationships'], quote_columns, lookup_cache) -%}
            {%- do dbt_constraints.flush_ddl_queue(lookup_cache) -%}
        {%- endif -%}

        {%- do log("Finished dbt Constraints", info=true) -%}
    {%- endif -%}

{%- endmacro -%}


{#- Index graph.nodes by unique_id, once per run.

    Upstream resolves a node with
    `graph.nodes.values() | selectattr("unique_id", "equalto", id)`, which is a
    full scan of the graph, executed once for every entry in every constraint
    test's depends_on list, across seven phases. This turns that into a dict
    lookup. Only graph.nodes is indexed, matching exactly what upstream scans. -#}
{%- macro node_index(lookup_cache) -%}
    {%- if lookup_cache.get('nodes_by_id') is none -%}
        {%- set index = {} -%}
        {%- for node in graph.nodes.values() -%}
            {%- do index.update({node.unique_id: node}) -%}
        {%- endfor -%}
        {%- do lookup_cache.update({'nodes_by_id': index}) -%}
    {%- endif -%}
    {{ return(lookup_cache.nodes_by_id) }}
{%- endmacro -%}


{#- Map a model's unique_id to the foreign-key tests that depend on it.

    test_selected needs this to answer PK_UK_FOR_SELECTED_FK, and computes it
    today by scanning the whole graph once per primary or unique key test. -#}
{%- macro fk_tests_by_parent(lookup_cache) -%}
    {%- if lookup_cache.get('fk_by_parent') is none -%}
        {%- set index = {} -%}
        {%- for fk_model in graph.nodes.values() | selectattr("resource_type", "equalto", "test")
                if fk_model.test_metadata
                and fk_model.test_metadata.name
                and fk_model.test_metadata.name in ("foreign_key", "relationships")
                and fk_model.depends_on
                and fk_model.depends_on.nodes -%}
            {%- for parent_id in fk_model.depends_on.nodes -%}
                {%- if parent_id not in index -%}
                    {%- do index.update({parent_id: []}) -%}
                {%- endif -%}
                {%- do index[parent_id].append(fk_model) -%}
            {%- endfor -%}
        {%- endfor -%}
        {%- do lookup_cache.update({'fk_by_parent': index}) -%}
    {%- endif -%}
    {{ return(lookup_cache.fk_by_parent) }}
{%- endmacro -%}


{#- Collect the databases and schemas the warm should cover, as a dict of
    {database: [schema, ...]}.

    Scope is every test's `attached_node`, the model the constraint is actually
    written to, and deliberately NOT the rest of its `depends_on`. A foreign
    key's parent is frequently in another database entirely: under deferral the
    child builds into a PR schema while the parent resolves to production. A
    parent-inclusive scope therefore warms a whole second database to answer a
    handful of lookups, which on a large warehouse costs more than it saves.

    Parents outside the warmed set are not lost, they just fall through to
    upstream's per-table SHOW, which is bounded by the number of distinct
    parents rather than by the size of their database. In a normal deployment
    the parents are dims carrying their own primary key tests, so their schema
    is already a warm target and nothing falls through at all. -#}
{%- macro constraint_warm_targets(constraint_types) -%}
    {%- set targets = {} -%}
    {%- for test_model in graph.nodes.values() | selectattr("resource_type", "equalto", "test")
            if test_model.test_metadata
            and test_model.test_metadata.name
            and test_model.test_metadata.name is in( constraint_types )
            and test_model.attached_node -%}
        {%- set node = graph.nodes.get(test_model.attached_node) -%}
        {%- if node and node.database and node.schema -%}
            {%- set db = node.database | upper -%}
            {%- if db not in targets -%}
                {%- do targets.update({db: []}) -%}
            {%- endif -%}
            {%- if (node.schema | upper) not in targets[db] -%}
                {%- do targets[db].append(node.schema | upper) -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
    {{ return(targets) }}
{%- endmacro -%}


{#- This macro checks if a test or its model is selected -#}
{%- macro test_selected(test_model, lookup_cache) -%}

    {%- if test_model.unique_id in selected_resources -%}
        {{ return("TEST_SELECTED") }}
    {%- endif -%}
    {%- if test_model.attached_node in selected_resources -%} -%}
        {{ return("MODEL_SELECTED") }}
    {%- endif -%}

    {#- Check if a PK/UK should be created because it is referenced by a selected FK -#}
    {%- if test_model.test_metadata.name in ("primary_key", "unique_key", "unique_combination_of_columns", "unique") -%}
        {#- Handle both dbt-core kwargs and Fusion arguments format -#}
        {%- set raw_pk_kwargs = test_model.test_metadata.kwargs -%}
        {%- if raw_pk_kwargs.arguments is defined -%}
            {%- set pk_test_args = {} -%}
            {%- for key, value in raw_pk_kwargs.items() -%}
                {%- if key != 'arguments' -%}
                    {%- do pk_test_args.update({key: value}) -%}
                {%- endif -%}
            {%- endfor -%}
            {%- do pk_test_args.update(raw_pk_kwargs.arguments) -%}
        {%- else -%}
            {%- set pk_test_args = raw_pk_kwargs -%}
        {%- endif -%}
        {%- set pk_test_columns = [] -%}
        {%- if pk_test_args.column_names -%}
            {%- set pk_test_columns =  pk_test_args.column_names -%}
        {%- elif pk_test_args.combination_of_columns -%}
            {%- set pk_test_columns =  pk_test_args.combination_of_columns -%}
        {%- elif pk_test_args.column_name -%}
            {%- set pk_test_columns =  [pk_test_args.column_name] -%}
        {%- endif -%}
        {#- The index is already keyed on depends_on membership, so upstream's
            `test_model.attached_node in fk_model.depends_on.nodes` is implied. -#}
        {%- for fk_model in dbt_constraints.fk_tests_by_parent(lookup_cache).get(test_model.attached_node, [])
                if ( (fk_model.unique_id and fk_model.unique_id in selected_resources)
                    or (fk_model.attached_node and fk_model.attached_node in selected_resources) ) -%}
            {#- Handle both dbt-core kwargs and Fusion arguments format -#}
            {%- set raw_fk_kwargs = fk_model.test_metadata.kwargs -%}
            {%- if raw_fk_kwargs.arguments is defined -%}
                {%- set fk_test_args = {} -%}
                {%- for key, value in raw_fk_kwargs.items() -%}
                    {%- if key != 'arguments' -%}
                        {%- do fk_test_args.update({key: value}) -%}
                    {%- endif -%}
                {%- endfor -%}
                {%- do fk_test_args.update(raw_fk_kwargs.arguments) -%}
            {%- else -%}
                {%- set fk_test_args = raw_fk_kwargs -%}
            {%- endif -%}
            {%- set fk_test_columns = [] -%}
            {%- if fk_test_args.pk_column_names -%}
                {%- set fk_test_columns =  fk_test_args.pk_column_names -%}
            {%- elif fk_test_args.pk_column_name -%}
                {%- set fk_test_columns =  [fk_test_args.pk_column_name] -%}
            {%- elif fk_test_args.field -%}
                {%- set fk_test_columns =  [fk_test_args.field] -%}
            {%- endif -%}
            {%- if column_list_matches(pk_test_columns, fk_test_columns) -%}
                {{ return("PK_UK_FOR_SELECTED_FK") }}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {{ return(none) }}
{%- endmacro -%}


{#- This macro that checks if a test has results and whether there were errors -#}
{%- macro lookup_should_rely(test_model) -%}
    {%- if test_model.config.where
            or test_model.config.warn_if != "!= 0"
            or test_model.config.fail_calc != "count(*)" -%}
        {#- Set NORELY if there is a condition on the test -#}
        {{ return('NORELY') }}
    {%- endif -%}

    {%- for res in results
        if res.node.config.materialized == "test"
        and res.node.unique_id == test_model.unique_id -%}
        {%- if res.failures == None -%}
            {#- Set '' if we do not know if there is a test failure -#}
            {{ return('') }}
        {%- elif res.failures > 0 -%}
            {#- Set NORELY if there is a test failure -#}
            {{ return('NORELY') }}
        {%- elif res.failures == 0 -%}
            {#- Set RELY if there are 0 failures -#}
            {{ return('RELY') }}
        {%- endif -%}
    {%- endfor -%}
    {{ return('') }}
{%- endmacro -%}


{#- This macro that checks if a test or its model has always_create_constraint set -#}
{%- macro should_always_create_constraint(test_model, lookup_cache) -%}
    {%- if test_model.config.get("always_create_constraint", "false")|string|lower == "true"
        or test_model.config.get("meta", {}).get("always_create_constraint", "false")|string|lower == "true" -%}
        {{ return(true) }}
    {%- endif -%}
    {%- for table_node in test_model.depends_on.nodes -%}
        {%- set candidate = dbt_constraints.node_index(lookup_cache).get(table_node) -%}
        {%- for node in ([candidate] if candidate else [])
            if node.config.get("always_create_constraint", "false")|string|lower == "true"
            or node.config.get("meta", {}).get("always_create_constraint", "false")|string|lower == "true" -%}
            {{ return(true) }}
        {%- endfor -%}
    {%- endfor -%}

    {{ return(false) }}
{%- endmacro -%}


{#- This macro is called internally and passed which constraint types to create. -#}
{%- macro create_constraints_by_type(constraint_types, quote_columns, lookup_cache) -%}

    {#- Global settings -#}
    {%- set dbt_constraints_sources_enabled = var('dbt_constraints_sources_enabled', "false")|string|lower == "true" %}
    {%- set dbt_constraints_sources_pk_enabled = var('dbt_constraints_sources_pk_enabled', "false")|string|lower == "true" %}
    {%- set dbt_constraints_sources_uk_enabled = var('dbt_constraints_sources_uk_enabled', "false")|string|lower == "true" %}
    {%- set dbt_constraints_sources_fk_enabled = var('dbt_constraints_sources_fk_enabled', "false")|string|lower == "true" %}
    {%- set dbt_constraints_sources_nn_enabled = var('dbt_constraints_sources_nn_enabled', "false")|string|lower == "true" %}
    {%- set dbt_constraints_always_norely = var('dbt_constraints_always_norely', "false")|string|lower == "true" %}

    {#- Loop through the metadata and find all tests that match the constraint_types and have all the fields we check for tests -#}
    {%- for test_model in graph.nodes.values() | selectattr("resource_type", "equalto", "test")
            if test_model.test_metadata
            and test_model.test_metadata.kwargs
            and test_model.test_metadata.name
            and test_model.test_metadata.name is in( constraint_types )
            and test_model.unique_id
            and test_model.attached_node
            and test_model.depends_on
            and test_model.depends_on.nodes
            and test_model.config
            and test_model.config.enabled
            and ( test_model.config.get("dbt_constraints_enabled", "true")|string|lower == "true"
                or test_model.config.get("meta", {}).get("dbt_constraints_enabled", "true")|string|lower == "true" ) -%}

        {#- In dbt Fusion, test arguments may be nested under 'arguments' key -#}
        {%- set raw_kwargs = test_model.test_metadata.kwargs -%}
        {%- if raw_kwargs.get('arguments') is not none -%}
            {#- Fusion format: merge column_name with arguments -#}
            {%- set test_parameters = {} -%}
            {%- for key, value in raw_kwargs.items() -%}
                {%- if key != 'arguments' -%}
                    {%- do test_parameters.update({key: value}) -%}
                {%- endif -%}
            {%- endfor -%}
            {%- do test_parameters.update(raw_kwargs.get('arguments')) -%}
        {%- else -%}
            {%- set test_parameters = raw_kwargs -%}
        {%- endif -%}
        {%- set test_name = test_model.test_metadata.name -%}
        {%- set selected = none if dbt_constraints.model_build_failed(test_model, lookup_cache)
                           else dbt_constraints.test_selected(test_model, lookup_cache) -%}

        {#- We can shortcut additional tests if the constraint was not selected -#}
        {%- if selected is not none and dbt_constraints_always_norely -%}
            {#- We can skip checking for NORELY if we always NORELY -#}
            {%- set rely_clause = 'NORELY' -%}
            {%- set always_create_constraint = dbt_constraints.should_always_create_constraint(test_model, lookup_cache) -%}
        {%- elif selected is not none -%}
            {#- rely_clause clause will be RELY if a test passed, NORELY if it failed, and '' if it was skipped -#}
            {%- set rely_clause = dbt_constraints.lookup_should_rely(test_model) -%}
            {%- set always_create_constraint = dbt_constraints.should_always_create_constraint(test_model, lookup_cache) -%}
        {%- else -%}
            {%- set rely_clause = '' -%}
            {%- set always_create_constraint = false -%}
        {%- endif -%}

        {#- Create constraints that:
            - Either the test or its model was selected to run, including PK/UK for FK
            - Passed the test (RELY) or the database supports NORELY constraints
            - We ran the test (RELY/NORELY) or we need the constraint for a FK
              or we have the always_create_constraint parameter turned on -#}
        {%- if selected is not none
            and ( rely_clause == 'RELY'
                  or dbt_constraints.adapter_supports_rely_norely(test_name) == true )
            and ( rely_clause in('RELY', 'NORELY')
                  or selected == "PK_UK_FOR_SELECTED_FK"
                  or always_create_constraint == true ) -%}

            {% set ns = namespace(verify_permissions=false) %}
            {%- set table_models = [] -%}

            {#- Find the table models that are referenced by this test. -#}
            {%- for table_node in test_model.depends_on.nodes -%}
                {%- set candidate = dbt_constraints.node_index(lookup_cache).get(table_node) -%}
                {%- for node in ([candidate] if candidate else [])
                    if node.config
                    and ( node.config.get("materialized", "other") not in ("view", "ephemeral", "dynamic_table")
                        or node.config.get("meta", {}).get("materialized", "other") not in ("view", "ephemeral", "dynamic_table") )
                    and ( node.resource_type in ("model", "snapshot", "seed")
                        or ( node.resource_type == "source" and dbt_constraints_sources_enabled
                            and ( ( dbt_constraints_sources_pk_enabled and test_name in("primary_key") )
                                or ( dbt_constraints_sources_uk_enabled and test_name in("unique_key", "unique_combination_of_columns", "unique") )
                                or ( dbt_constraints_sources_fk_enabled and test_name in("foreign_key", "relationships") )
                                or ( dbt_constraints_sources_nn_enabled and test_name in("not_null") ) )
                        ) ) -%}

                    {#- Resolve the physical identifier, accounting for versioned models.
                       For versioned models dbt materialises the table as `<name>_v<version>`,
                       but `node.alias`/`node.name` may still be the unversioned form.
                       Prefer `node.relation_name` (e.g. `"DB"."SCH"."MY_MODEL_V1"`) when set;
                       otherwise append `_v<version>` if not already present. -#}
                    {%- set _node_alias = node.alias or node.name -%}
                    {%- if node.get('version') is not none -%}
                        {%- if node.get('relation_name') -%}
                            {%- set _node_alias = node.relation_name.split('.')[-1] | replace('"', '') -%}
                        {%- elif not (_node_alias.endswith('_v' ~ node.version | string)) -%}
                            {%- set _node_alias = _node_alias ~ '_v' ~ node.version -%}
                        {%- endif -%}
                    {%- endif -%}
                    {%- do node.update({'alias': _node_alias}) -%}
                    {#- Append to our list of models for this test -#}
                    {%- do table_models.append(node) -%}
                    {%- if node.resource_type == "source"
                        or node.config.get("materialized", "other") not in ("table", "incremental", "snapshot", "seed")
                        or node.config.get("meta", {}).get("materialized", "other") not in ("table", "incremental", "snapshot", "seed") -%}
                        {#- If we are using a sources or custom materializations, we will need to verify permissions -#}
                        {%- set ns.verify_permissions = true -%}
                    {%- endif -%}

                {% endfor %}
            {% endfor %}

            {#- We only create PK/UK if there is one model referenced by the test
                and if all the columns exist as physical columns on the table -#}
            {%- if 1 == table_models|count
                and test_name in("primary_key", "unique_key", "unique_combination_of_columns", "unique") -%}

                {# Attempt to identify a parameter we can use for the column names #}
                {%- set column_names = [] -%}
                {%- if  test_parameters.column_names -%}
                    {%- set column_names =  test_parameters.column_names -%}
                {%- elif  test_parameters.combination_of_columns -%}
                    {%- set column_names =  test_parameters.combination_of_columns -%}
                {%- elif  test_parameters.column_name -%}
                    {%- set column_names =  [test_parameters.column_name] -%}
                {%- else  -%}
                    {{ exceptions.raise_compiler_error(
                    "`column_names` or `column_name` parameter missing for primary/unique key constraint on table: '" ~ table_models[0].name
                    ) }}
                {%- endif -%}

                {%- set table_relation = adapter.get_relation(
                    database=table_models[0].database,
                    schema=table_models[0].schema,
                    identifier=table_models[0].alias ) -%}
                {%- if table_relation and table_relation.is_table -%}
                    {%- if dbt_constraints.table_columns_all_exist(table_relation, column_names, lookup_cache, allow_contract_shortcut=true) -%}
                        {%- if test_name == "primary_key" or (target.type == "bigquery"
                            and test_name in("unique_key", "unique_combination_of_columns", "unique"))
                        -%}
                            {%- if dbt_constraints.adapter_supports_rely_norely("not_null") == true -%}
                                {%- do dbt_constraints.create_not_null(table_relation, column_names, ns.verify_permissions, quote_columns, lookup_cache, rely_clause) -%}
                            {%- endif -%}
                            {%- do dbt_constraints.create_primary_key(table_relation, column_names, ns.verify_permissions, quote_columns, test_parameters.constraint_name, lookup_cache, rely_clause) -%}
                        {%- else  -%}
                            {%- do dbt_constraints.create_unique_key(table_relation, column_names, ns.verify_permissions, quote_columns, test_parameters.constraint_name, lookup_cache, rely_clause) -%}
                        {%- endif -%}
                    {%- else  -%}
                        {%- do log("Skipping primary/unique key because a physical column name was not found on the table: " ~ table_models[0].name ~ " " ~ column_names, info=true) -%}
                    {%- endif -%}
                {%- else  -%}
                    {%- do log("Skipping primary/unique key because the table was not found in the database: " ~ table_models[0].name, info=true) -%}
                {%- endif -%}

            {#- We only create FK if there are two models referenced by the test
                and if all the columns exist as physical columns on the tables -#}
            {%- elif 2 == table_models|count
                and test_name in( "foreign_key", "relationships") -%}

                {%- set fk_model = table_models | selectattr("unique_id", "equalto", test_model.attached_node) | first -%}
                {%- set pk_model = table_models | rejectattr("unique_id", "equalto", test_model.attached_node) | first -%}

                {%- if fk_model and pk_model -%}

                    {%- set fk_table_relation = adapter.get_relation(
                        database=fk_model.database,
                        schema=fk_model.schema,
                        identifier=fk_model.alias) -%}

                    {%- if pk_model.unique_id not in selected_resources -%}
                        {%- set pk_table_relation = adapter.get_relation(
                            database=(pk_model.database or pk_model.config.database),
                            schema=(pk_model.schema or pk_model.config.schema),
                            identifier=(pk_model.alias or pk_model.config.alias)) -%}
                    {%- else -%}
                        {%- set pk_table_relation = adapter.get_relation(
                            database=pk_model.database,
                            schema=pk_model.schema,
                            identifier=pk_model.alias) -%}
                    {%- endif -%}

                    {%- if fk_table_relation and pk_table_relation and fk_table_relation.is_table and pk_table_relation.is_table-%}
                        {# Attempt to identify parameters we can use for the column names #}
                        {%- set pk_column_names = [] -%}
                        {%- if  test_parameters.pk_column_names -%}
                            {%- set pk_column_names = test_parameters.pk_column_names -%}
                        {%- elif  test_parameters.field -%}
                            {%- set pk_column_names = [test_parameters.field] -%}
                        {%- elif test_parameters.pk_column_name -%}
                            {%- set pk_column_names = [test_parameters.pk_column_name] -%}
                        {%- endif -%}

                        {%- set fk_column_names = [] -%}
                        {%- if  test_parameters.fk_column_names -%}
                            {%- set fk_column_names = test_parameters.fk_column_names -%}
                        {%- elif test_parameters.column_name -%}
                            {%- set fk_column_names = [test_parameters.column_name] -%}
                        {%- elif test_parameters.fk_column_name -%}
                            {%- set fk_column_names = [test_parameters.fk_column_name] -%}
                        {%- endif -%}

                        {#- Skip constraint if required parameters are missing.
                           This was the dominant failure mode on dbt Fusion < preview.176, where
                           test_metadata.kwargs did not expose the parameterised generic test
                           arguments (dbt-fusion#1575). Fusion >= preview.176 populates the
                           arguments correctly; reaching this branch on a modern Fusion or
                           dbt-core indicates a genuine misconfiguration in the test definition. -#}
                        {%- if pk_column_names | length == 0 -%}
                            {%- do log("Skipping foreign key on " ~ fk_model.name ~ " because pk_column_name/field is missing from test parameters", info=true) -%}
                        {%- elif fk_column_names | length == 0 -%}
                            {%- do log("Skipping foreign key on " ~ fk_model.name ~ " because fk_column_name/column_name is missing from test parameters", info=true) -%}
                        {%- elif not dbt_constraints.table_columns_all_exist(pk_table_relation, pk_column_names, lookup_cache, allow_contract_shortcut=true) -%}
                            {%- do log("Skipping foreign key because a physical column was not found on the pk table: " ~ pk_model.name ~ " " ~ pk_column_names, info=true) -%}
                        {%- elif not dbt_constraints.table_columns_all_exist(fk_table_relation, fk_column_names, lookup_cache, allow_contract_shortcut=true) -%}
                            {%- do log("Skipping foreign key because a physical column was not found on the fk table: " ~ fk_model.name ~ " " ~ fk_column_names, info=true) -%}
                        {%- else  -%}
                            {%- do dbt_constraints.create_foreign_key(pk_table_relation, pk_column_names, fk_table_relation, fk_column_names, ns.verify_permissions, quote_columns, test_parameters.constraint_name, lookup_cache, rely_clause) -%}
                        {%- endif -%}
                    {%- else  -%}
                        {%- if fk_table_relation is none or not fk_table_relation.is_table -%}
                            {%- do log("Skipping foreign key to " ~ pk_model.alias ~ " because the child table was not found in the database: " ~ fk_model.alias, info=true) -%}
                        {%- endif -%}
                        {%- if pk_table_relation is none or not pk_table_relation.is_table -%}
                            {%- do log("Skipping foreign key on " ~ fk_model.alias ~ " because the parent table was not found in the database: " ~ pk_model.alias, info=true) -%}
                        {%- endif -%}
                    {%- endif -%}

                {%- else  -%}
                    {%- do log("Skipping foreign key because a we couldn't find the child table: model=" ~ test_model.attached_node ~ " or source", info=true) -%}
                {%- endif -%}

            {#- We only create NN if there is one model referenced by the test
                and if all the columns exist as physical columns on the table -#}
            {%- elif 1 == table_models|count
                and test_name in("not_null") -%}

                {# Attempt to identify a parameter we can use for the column names #}
                {%- set column_names = [] -%}
                {%- if  test_parameters.column_names -%}
                    {%- set column_names =  test_parameters.column_names -%}
                {%- elif  test_parameters.combination_of_columns -%}
                    {%- set column_names =  test_parameters.combination_of_columns -%}
                {%- elif  test_parameters.column_name -%}
                    {%- set column_names =  [test_parameters.column_name] -%}
                {%- else  -%}
                    {{ exceptions.raise_compiler_error(
                    "`column_names` or `column_name` parameter missing for not null constraint on table: '" ~ table_models[0].name
                    ) }}
                {%- endif -%}

                {%- set table_relation = adapter.get_relation(
                    database=table_models[0].database,
                    schema=table_models[0].schema,
                    identifier=table_models[0].alias ) -%}

                {%- if table_relation and table_relation.is_table -%}
                    {%- if dbt_constraints.table_columns_all_exist(table_relation, column_names, lookup_cache) -%}
                        {%- do dbt_constraints.create_not_null(table_relation, column_names, ns.verify_permissions, quote_columns, lookup_cache, rely_clause) -%}
                    {%- else  -%}
                        {%- do log("Skipping not null constraint because a physical column name was not found on the table: " ~ table_models[0].name ~ " " ~ column_names, info=true) -%}
                    {%- endif -%}
                {%- else  -%}
                    {%- do log("Skipping not null constraint because the table was not found in the database: " ~ table_models[0].name, info=true) -%}
                {%- endif -%}

            {%- endif -%}
        {%- endif -%}


    {%- endfor -%}

{%- endmacro -%}



{#- Whether this test's model failed or was skipped in this invocation.

    A model that errored or was skipped was not successfully built, so its table
    is either absent or holds the previous run's rows. Reconciling constraints
    against it costs metadata lookups and DDL to reach a state the next
    successful build will redo anyway, and on a first build the table does not
    exist at all, which upstream discovers only by asking the database.

    Deliberately narrow: only an explicit error or skip suppresses the
    constraint. A model absent from `results` entirely is left alone, because
    that is the ordinary case for a run that did not select it, and upstream's
    `selected_resources` check already governs it. -#}
{%- macro model_build_failed(test_model, lookup_cache) -%}
    {%- if lookup_cache.get('result_status') is none -%}
        {%- set status = {} -%}
        {%- for res in results if res.node and res.node.unique_id -%}
            {%- do status.update({res.node.unique_id: res.status | string | lower}) -%}
        {%- endfor -%}
        {%- do lookup_cache.update({'result_status': status}) -%}
    {%- endif -%}
    {{ return( lookup_cache.result_status.get(test_model.attached_node) in ('error', 'skipped') ) }}
{%- endmacro -%}


{#- Relations whose model declares an enforced dbt contract, keyed the same way
    as the bulk cache. Built once per run.

    A contract makes dbt fail the build when a model's output columns do not
    match its declared `columns:`, and a constraint test's column comes from that
    same declaration. So on a contract-enforced model the question
    `table_columns_all_exist` asks has already been answered, at build time,
    more strictly than a metadata lookup could answer it. -#}
{%- macro contracted_relations(lookup_cache) -%}
    {%- if lookup_cache.get('contracted') is none -%}
        {%- set contracted = {} -%}
        {%- for node in graph.nodes.values()
                if node.config
                and node.config.get('contract')
                and node.config.get('contract').get('enforced')|string|lower == 'true'
                and node.database and node.schema -%}
            {%- set key = (node.database ~ '.' ~ node.schema ~ '.' ~ (node.alias or node.name)) | upper -%}
            {%- do contracted.update({key: true}) -%}
        {%- endfor -%}
        {%- do lookup_cache.update({'contracted': contracted}) -%}
    {%- endif -%}
    {{ return(lookup_cache.contracted) }}
{%- endmacro -%}


{#- This macro tests that all the column names passed to the macro can be found
    on the table, ignoring case.

    `allow_contract_shortcut` skips the metadata lookup entirely when the model
    carries an enforced contract. Callers pass it for the primary key, unique
    key and foreign key paths, where the only thing being checked is column
    existence. The not-null path must NOT pass it, because it goes on to read
    nullability and semi-structured types out of the same cache entry, which
    only the lookup populates. -#}
{%- macro table_columns_all_exist(table_relation, column_list, lookup_cache, allow_contract_shortcut=false) -%}
    {%- if allow_contract_shortcut
           and dbt_constraints.relation_cache_key(table_relation) in dbt_constraints.contracted_relations(lookup_cache) -%}
        {{ return(true) }}
    {%- endif -%}
    {%- set tab_column_list = dbt_constraints.lookup_table_columns(table_relation, lookup_cache) -%}
    {%- set check_columns = column_list|map('upper')|map('trim', '"')|list -%}
    {%- for column in check_columns if column not in tab_column_list -%}
        {{ return(false) }}
    {%- endfor -%}
    {{ return(true) }}
{%- endmacro -%}


{%- macro lookup_table_columns(table_relation, lookup_cache) -%}
    {{ return(adapter.dispatch('lookup_table_columns', 'dbt_constraints')(table_relation, lookup_cache)) }}
{%- endmacro -%}


{#- Dispatch wrapper for `lookup_table_privileges`. Adapters that support privilege
    introspection (Snowflake, Vertica) override this; others fall through to a
    no-op that returns an empty list. The wrapper namespaces the call to the
    `dbt_constraints` package, which is required when users invoke
    `dbt_constraints.create_constraints()` directly from their own on-run-end. -#}
{%- macro lookup_table_privileges(table_relation, lookup_cache) -%}
    {{ return(adapter.dispatch('lookup_table_privileges', 'dbt_constraints')(table_relation, lookup_cache)) }}
{%- endmacro -%}


{%- macro default__lookup_table_privileges(table_relation, lookup_cache) -%}
    {{ return([]) }}
{%- endmacro -%}


{%- macro default__lookup_table_columns(table_relation, lookup_cache) -%}
    {%- if table_relation not in lookup_cache.table_columns -%}
        {%- set tab_Columns = adapter.get_columns_in_relation(table_relation) -%}

        {%- set tab_column_list = [] -%}
        {%- for column in tab_Columns -%}
            {% do tab_column_list.append(column.name|upper|trim('"')) %}
        {%- endfor -%}
        {%- do lookup_cache.table_columns.update({ table_relation: tab_column_list }) -%}
    {%- endif -%}
    {{ return(lookup_cache.table_columns[table_relation]) }}
{%- endmacro -%}


{#- This macro provides a group_by function for query results that works in both dbt-core and dbt Fusion.
    It takes a query result set and groups the rows by the specified column name.
    Returns a dictionary where keys are the unique values of the group_by column
    and values are lists of row dictionaries with that key. -#}
{%- macro get_results_group_by(query_results, group_by_column) -%}
    {%- set grouped = {} -%}
    {%- for row in query_results.rows -%}
        {%- set key = row[group_by_column] -%}
        {%- if key not in grouped -%}
            {%- do grouped.update({key: []}) -%}
        {%- endif -%}
        {%- do grouped[key].append(row) -%}
    {%- endfor -%}
    {{ return(grouped) }}
{%- endmacro -%}


{#- Sanitise an auto-generated constraint name so it is a legal unquoted SQL
    identifier across all supported adapters. Strips double quotes and replaces
    every other non-[A-Z0-9_$] character with `_`. Required when source columns
    contain parentheses, spaces, dashes, dots, or other punctuation that would
    otherwise be carried through into the generated `<TABLE>_<COL>_PK` name and
    rejected as invalid identifier syntax (issue #107). -#}
{%- macro sanitize_constraint_name(name) -%}
    {%- set _name = name | upper | replace('"', '') -%}
    {{ return(modules.re.sub('[^A-Z0-9_$]', '_', _name)) }}
{%- endmacro -%}


{# This macro allows us to compare two sets of columns to see if they are the same, ignoring case #}
{%- macro column_list_matches(listA, listB) -%}
    {%- set testListA = listA | map('upper') | map('trim', '"') | list -%}
    {%- set testListB = listB | map('upper') | map('trim', '"') | list -%}
    {# Test if A is empty or the lists are not the same size #}
    {%- if listA | count > 0 and listA | count == listB | count  -%}
        {# Fail if there are any columns in A that are not in B #}
        {%- for valueFromA in testListA -%}
            {%- if valueFromA not in testListB  -%}
                {{ return(false) }}
            {%- endif -%}
        {% endfor %}
        {# Since we know the count is the same, A must equal B #}
        {{ return(true) }}
    {%- else -%}
        {{ return(false) }}
    {%- endif -%}
{%- endmacro -%}
