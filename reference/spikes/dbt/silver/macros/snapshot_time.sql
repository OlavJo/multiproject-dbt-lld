{#- Snapshot validity timestamps come from the unit watermark, not the clock (SLD 6.7, S4).
    The freeze records the watermark in <unit>__build._freeze. A snapshot run during a
    publication stamps dbt_valid_from, dbt_valid_to and dbt_updated_at with it, so a build
    that is discarded and retried at the same watermark stamps the same time.
    Outside a publication (parse, development) the clock is used. -#}
{% macro snowflake__snapshot_get_time() -%}
  {%- if execute and var('publish_unit', none) is not none -%}
    {%- set q -%}select to_varchar(watermark, 'YYYY-MM-DD HH24:MI:SS.FF3') from {{ target.database }}.{{ unit_schema(var('publish_unit')) }}._freeze{%- endset -%}
    {%- set r = run_query(q) -%}
    to_timestamp_ntz('{{ r.columns[0].values()[0] }}')
  {%- else -%}
    to_timestamp_ntz({{ current_timestamp() }})
  {%- endif -%}
{%- endmacro %}
