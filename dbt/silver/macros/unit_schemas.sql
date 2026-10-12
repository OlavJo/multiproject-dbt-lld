{#- Schema redirection (SLD 10.4).
    prod targets: a unit's objects live in its published schema, except for the unit being
    published, whose objects are built in <unit>__build and swapped in by the publish procedure.
    Increment 3 adds input clones for units that read other Silver units. -#}

{% macro is_prod() -%}
  {{ return(target.name.startswith('prod')) }}
{%- endmacro %}

{% macro unit_schema(unit) -%}
  {%- if is_prod() and unit == var('publish_unit', none) -%}
    {{ return(unit ~ '__build') }}
  {%- elif is_prod() -%}
    {{ return(unit) }}
  {%- else -%}
    {{ return(target.schema ~ '_' ~ unit) }}
  {%- endif -%}
{%- endmacro %}

{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- if custom_schema_name is none -%}
    {{ return(target.schema) }}
  {%- else -%}
    {{ return(unit_schema(custom_schema_name | trim)) }}
  {%- endif -%}
{%- endmacro %}
