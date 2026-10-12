{#- ref() and source() overrides (SLD 10.5; spike S1).
    A view that references an object in its own schema uses a bare identifier, so the reference
    follows the view when the build schema is swapped in. Everything else stays fully qualified. -#}

{% macro bare_if_same_schema(rel) -%}
  {%- if execute and model is defined and model.resource_type == 'model'
        and model.config.materialized == 'view'
        and rel.database | lower == this.database | lower
        and rel.schema | lower == this.schema | lower -%}
    {{ return(rel.include(database=false, schema=false)) }}
  {%- endif -%}
  {{ return(rel) }}
{%- endmacro %}

{% macro ref() -%}
  {{ return(bare_if_same_schema(builtins.ref(*varargs, **kwargs))) }}
{%- endmacro %}

{#- Frozen-input sources (<unit>_frozen) are declared with the published schema, because project
    macros are not available when source properties render; the schema is redirected here. -#}
{% macro source(source_name, table_name) -%}
  {%- set ns = namespace(rel=builtins.source(source_name, table_name)) -%}
  {%- if source_name.endswith('_frozen') -%}
    {%- set ns.rel = ns.rel.incorporate(path={'schema': unit_schema(source_name[:-7])}) -%}
  {%- endif -%}
  {{ return(bare_if_same_schema(ns.rel)) }}
{%- endmacro %}
