-- CDC history (SLD 6.7, G8): one row per key per version. valid_from is the source commit time,
-- valid_to the commit time of the next version by the source ordering column; a delete is a
-- tombstone version. Incremental, keyed on (order_id, source_seq): each run recomputes the
-- validity of every key that received a change (a late change closes and opens its neighbours;
-- a redelivered change is deduplicated), reading the key's existing versions from this table,
-- because raw's change log cannot be relied on beyond its retention. Permanent.
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['order_id', 'source_seq'],
    transient=false,
    on_schema_change='fail'
) }}

with src as (
    select order_id, status, amount, op, source_seq, commit_ts, loaded_at
    from {{ ref('stg_s4__orders_cdc') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),
affected as (
    select distinct order_id from src
),
existing as (
    {% if is_incremental() %}
    select order_id, status, amount, op, source_seq, commit_ts, loaded_at
    from {{ this }}
    where order_id in (select order_id from affected)
    {% else %}
    select order_id, status, amount, op, source_seq, commit_ts, loaded_at from src where false
    {% endif %}
),
deduplicated as (
    select * from (select * from src union all select * from existing)
    qualify row_number() over (partition by order_id, source_seq order by loaded_at) = 1
)
select
    order_id, status, amount, op, source_seq, commit_ts, loaded_at,
    commit_ts as valid_from,
    lead(commit_ts) over (partition by order_id order by source_seq) as valid_to,
    op = 'D' as is_deleted
from deduplicated
