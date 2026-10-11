{#- The freeze (SLD 7.2): replace the unit's frozen inputs with transient clones of
    every raw table of its live source, all at one watermark.
    Invoked by the publish procedure with --vars '{publish_unit: <unit>}', so the
    clones land in <unit>__build.
      dbt run-operation freeze_sources --args '{unit: erp, watermark: "2026-10-06 12:00:00"}'
    watermark is a UTC TIMESTAMP_NTZ literal (S9: CLONE AT reads it as UTC). -#}
{% macro freeze_sources(unit, watermark) -%}
  {%- set live = [] -%}
  {%- for s in graph.sources.values() if s.source_name == unit ~ '_raw' -%}
    {%- do live.append(s) -%}
  {%- endfor -%}
  {%- if live | length == 0 -%}
    {{ exceptions.raise_compiler_error('freeze_sources: no tables declared for source ' ~ unit ~ '_raw') }}
  {%- endif -%}
  {#- dev and CI: nobody else creates the unit schema. In prod the publish procedure creates the
      build schema (a clone of the published one); creating it here would hide a missing clone. -#}
  {%- if not is_prod() -%}
    {%- do run_query("create schema if not exists " ~ target.database ~ "." ~ unit_schema(unit)) -%}
  {%- endif -%}
  {%- for s in live -%}
    {%- set stmt -%}
      create or replace transient table {{ target.database }}.{{ unit_schema(unit) }}.raw__{{ s.name }}
        clone {{ s.database }}.{{ s.schema }}.{{ s.identifier }}
        at (timestamp => '{{ watermark }}'::timestamp_ntz)
    {%- endset -%}
    {%- do log('freeze: ' ~ (stmt | replace('\n', ' ') | trim), info=true) -%}
    {%- do run_query(stmt) -%}
  {%- endfor -%}
  {#- The watermark is recorded beside the frozen inputs, so that snapshots can stamp their
      validity with it (S4: a retried build must stamp the same time). -#}
  {%- do run_query("create or replace transient table " ~ target.database ~ "." ~ unit_schema(unit) ~ "._freeze as select '" ~ unit ~ "' as unit, '" ~ watermark ~ "'::timestamp_ntz as watermark") -%}
{%- endmacro %}
