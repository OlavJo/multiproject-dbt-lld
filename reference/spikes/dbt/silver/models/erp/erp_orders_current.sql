{{ config(
    materialized='incremental',
    unique_key='order_id',
    on_schema_change='fail',
    grants={'select': ['ANALYST_TIER1']}
) }}

-- CDC current state: one current row per key, ordered by the source ordering
-- column (not _loaded_at alone; SLD 4.1). Reads the base view in this schema.
select order_id, account_id, status, amount, source_seq, loaded_at
from {{ ref('stg_erp__orders') }}
{% if is_incremental() %}
where loaded_at > (select max(loaded_at) from {{ this }})
{% endif %}
qualify row_number() over (partition by order_id order by source_seq desc) = 1
