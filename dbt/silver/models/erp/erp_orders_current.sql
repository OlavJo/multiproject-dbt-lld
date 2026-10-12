{{ config(materialized='incremental', unique_key='order_id', on_schema_change='fail') }}

-- CDC current state: one row per key, the latest by the source ordering column (SLD 4.1).
-- Incremental, so the table survives from one publication to the next: in the build schema it is
-- a clone of the published table, with the grants the clone carried (V-IA-1).
select order_id, account_id, status, amount, source_seq, loaded_at
from {{ ref('stg_erp__orders') }}
{% if is_incremental() %}
where loaded_at > (select max(loaded_at) from {{ this }})
{% endif %}
qualify row_number() over (partition by order_id order by source_seq desc) = 1
