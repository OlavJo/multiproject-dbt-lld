{#- Schema redirection (SLD 10.4, 10.9).
    prod targets: a unit's objects live in its published schema, except
      * for the unit being published, whose objects are built in <unit>__build and swapped in by the
        publish procedure, and
      * while that unit is published, for each upstream Silver unit it reads: the input clone
        <publish_unit>__in_<upstream>, taken at the gate (var input_clones, set by the procedure). -#}

{% macro is_prod() -%}
  {{ return(target.name.startswith('prod')) }}
{%- endmacro %}

{% macro unit_schema(unit) -%}
  {%- if is_prod() and unit == var('publish_unit', none) -%}
    {{ return(unit ~ '__build') }}
  {%- elif is_prod() and var('publish_unit', none) is not none and unit in var('input_clones', []) -%}
    {{ return(var('publish_unit') ~ '__in_' ~ unit) }}
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
