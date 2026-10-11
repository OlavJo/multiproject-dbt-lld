-- SCD2 history for a source without change capture (SLD 6.7, G8). The check strategy compares
-- every column of each frozen state to the last recorded one; the validity timestamps are the unit
-- watermark (macros/snapshot_time.sql), so a retried build stamps the same times.
{% snapshot s4_customers_snapshot %}
{{ config(
    schema='s4',
    unique_key='customer_id',
    strategy='check',
    check_cols='all',
    hard_deletes='invalidate',
    transient=false
) }}
select customer_id, name, tier from {{ ref('stg_s4__customers') }}
{% endsnapshot %}
