-- CDC current state: the latest change per key by the source ordering column, without deletes
{{ config(materialized='table', transient=true) }}

select order_id, status, amount, source_seq, commit_ts
from (
    select order_id, status, amount, op, source_seq, commit_ts,
           row_number() over (partition by order_id order by source_seq desc) as rn
    from {{ ref('stg_s4__orders_cdc') }}
)
where rn = 1 and op <> 'D'
