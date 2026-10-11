{#- Environment and schema redirection (SLD 10.4, Schema redirection) -#}

{% macro is_prod() -%}
  {{ return(target.name.startswith('prod')) }}
{%- endmacro %}

{#- The schema that holds a unit's objects in this invocation.
    prod: the published schema, or <unit>__build for the unit being published.
    other targets: <target.schema>_<unit> (everything in the developer's own schemas). -#}
{% macro unit_schema(unit) -%}
  {%- if is_prod() -%}
    {%- if unit == var('publish_unit', none) -%}
      {%- set s = unit ~ '__build' -%}
    {%- elif var('publish_unit', none) is not none
             and unit in (var('input_clones', {}).get(var('publish_unit'), [])) -%}
      {#- an upstream unit read by the unit being published: its input clone (SLD 10.9) -#}
      {%- set s = var('publish_unit') ~ '__in_' ~ unit -%}
    {%- else -%}
      {%- set s = unit -%}
    {%- endif -%}
  {%- else -%}
    {%- set s = target.schema ~ '_' ~ unit -%}
  {%- endif -%}
  {{ return(s) }}
{%- endmacro %}

{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- if custom_schema_name is none -%}
    {{ return(target.schema) }}
  {%- else -%}
    {{ return(unit_schema(custom_schema_name | trim)) }}
  {%- endif -%}
{%- endmacro %}
