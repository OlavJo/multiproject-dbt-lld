{#- ref() and source() overrides (SLD 10.5, S1).
    A view that references an object in its own schema uses a bare identifier, so
    the reference follows the view through a schema swap or clone. Everything else
    (tables, incrementals, tests, other schemas) stays fully qualified.
    Semantic views are not handled here: S1 showed they must reference published names. -#}

{% macro silver_bare_if_same_schema(rel) -%}
  {%- if execute and model is defined and model.resource_type == 'model'
        and model.config.materialized == 'view'
        and rel.database | lower == this.database | lower
        and rel.schema | lower == this.schema | lower -%}
    {{ return(rel.include(database=false, schema=false)) }}
  {%- endif -%}
  {{ return(rel) }}
{%- endmacro %}

{% macro ref() -%}
  {{ return(silver_bare_if_same_schema(builtins.ref(*varargs, **kwargs))) }}
{%- endmacro %}

{#- Frozen-input sources are declared with their published schema in YAML (project
    macros are not available when source properties are rendered). The schema of
    <unit>_frozen is redirected here, at compile time (SLD 10.4). -#}
{% macro source(source_name, table_name) -%}
  {%- set ns = namespace(rel=builtins.source(source_name, table_name)) -%}
  {%- if source_name.endswith('_frozen') -%}
    {%- set ns.rel = ns.rel.incorporate(path={'schema': unit_schema(source_name[:-7])}) -%}
  {%- endif -%}
  {{ return(silver_bare_if_same_schema(ns.rel)) }}
{%- endmacro %}
