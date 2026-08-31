{#- Copy one relation's entry out of the bulk cache into the relation-keyed
    cache that upstream's lookup macros already read from.

    Returns true when the bulk cache can answer for this relation, in which case
    the caller skips its SHOW commands entirely. Returns false when it cannot,
    and the caller must fall back to upstream's per-table lookup.

    An empty seed is a valid answer, not a miss. The bulk warm reads a whole
    database, so a table with no row in the constraint buckets genuinely has no
    constraints, and recording that as an empty dict is exactly what upstream
    would have concluded after two SHOW commands returning nothing. -#}
{%- macro bulk_seed(relation, bucket, lookup_cache) -%}
    {%- if lookup_cache.get('bulk') is none -%}
        {{ return(false) }}
    {%- endif -%}
    {%- if not dbt_constraints.bulk_cache_eligible(relation) -%}
        {{ return(false) }}
    {%- endif -%}
    {%- if (relation.database ~ '.' ~ relation.schema) | upper not in lookup_cache.bulk.warmed -%}
        {{ return(false) }}
    {%- endif -%}

    {%- set key = dbt_constraints.relation_cache_key(relation) -%}
    {%- do lookup_cache[bucket].update({ relation: lookup_cache.bulk[bucket].get(key, {}) }) -%}
    {{ return(true) }}
{%- endmacro -%}


{#- Whether the bulk cache holds column metadata for this relation.

    Unlike the constraint buckets, absence here is a genuine miss rather than a
    negative answer: every table has at least one column, so a table missing
    from the column bucket was simply not covered by the warm, most likely
    because its schema carried no constraint tests at warm time. -#}
{%- macro bulk_columns_available(relation, lookup_cache) -%}
    {%- if lookup_cache.get('bulk') is none -%}
        {{ return(false) }}
    {%- endif -%}
    {%- if not dbt_constraints.bulk_cache_eligible(relation) -%}
        {{ return(false) }}
    {%- endif -%}
    {%- if (relation.database ~ '.' ~ relation.schema) | upper not in lookup_cache.bulk.warmed -%}
        {{ return(false) }}
    {%- endif -%}
    {{ return( dbt_constraints.relation_cache_key(relation) in lookup_cache.bulk.columns ) }}
{%- endmacro -%}
