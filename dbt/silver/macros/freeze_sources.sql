{#- The freeze (SLD 7.2): replace the unit's frozen inputs with transient clones of every table
    of its live raw source (<unit>_raw), all at one watermark.
    Called by the publish procedure with --vars '{publish_unit: <unit>}', so the clones land in
    <unit>__build, which the procedure created as a clone of the published schema.
      dbt run-operation freeze_sources --args '{unit: erp, watermark: "2026-10-12T09:00:00.000"}'
    The watermark is a UTC TIMESTAMP_NTZ literal (spike S9). -#}
{% macro freeze_sources(unit, watermark) -%}
  {%- set live = [] -%}
  {%- for s in graph.sources.values() if s.source_name == unit ~ '_raw' -%}
    {%- do live.append(s) -%}
  {%- endfor -%}
  {%- if live | length == 0 -%}
    {{ exceptions.raise_compiler_error('freeze_sources: no tables declared for source ' ~ unit ~ '_raw') }}
  {%- endif -%}
  {%- set schema = target.database ~ '.' ~ unit_schema(unit) -%}
  {%- for s in live -%}
    {%- set stmt -%}
      create or replace transient table {{ schema }}.raw__{{ s.name }}
        clone {{ s.database }}.{{ s.schema }}.{{ s.identifier }}
        at (timestamp => '{{ watermark }}'::timestamp_ntz)
    {%- endset -%}
    {%- do log('freeze: ' ~ (stmt | replace('\n', ' ') | trim), info=true) -%}
    {%- do run_query(stmt) -%}
  {%- endfor -%}
  {%- do run_query("create or replace transient table " ~ schema ~ "._freeze as select '"
                   ~ unit ~ "' as unit, '" ~ watermark ~ "'::timestamp_ntz as watermark") -%}
{%- endmacro %}
