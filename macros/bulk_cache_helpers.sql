{#- Helpers shared by the bulk metadata cache.

    The bulk cache is keyed by a normalised, fully qualified name built from the
    strings that `SHOW ... IN DATABASE` and `INFORMATION_SCHEMA` return, whereas
    the per-table cache upstream already maintains is keyed by relation object.
    These two macros bridge the two keyings and gate out the one case where the
    bridge would be unsound. -#}


{#- Normalise a relation to the key shape used by the bulk metadata cache.

    Snowflake stores unquoted identifiers uppercased, and dbt renders relations
    unquoted by default, so uppercasing the rendered name is what matches the
    identifiers reported by SHOW. A lowercase identifier in the manifest is
    normal and safe: it is sent unquoted and resolved case-insensitively. -#}
{%- macro relation_cache_key(relation) -%}
    {{ return( (relation | string) | replace('"', '') | upper ) }}
{%- endmacro -%}


{#- Whether a relation can safely be answered from the bulk cache.

    A quoted identifier that is not already uppercase names a genuinely
    different object from its uppercased form, so folding it into an uppercase
    key would silently return another table's constraints. Such relations are
    excluded here and fall through to upstream's per-table SHOW lookups, which
    are slower but always correct. -#}
{%- macro bulk_cache_eligible(relation) -%}
    {%- set rendered = relation | string -%}
    {%- if '"' in rendered and rendered != rendered | upper -%}
        {{ return(false) }}
    {%- endif -%}
    {{ return(true) }}
{%- endmacro -%}
