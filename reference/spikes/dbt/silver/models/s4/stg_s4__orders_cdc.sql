select
    order_id::number(38, 0)    as order_id,
    status::varchar            as status,
    amount::number(18, 2)      as amount,
    _op::varchar               as op,
    _seq::number(38, 0)        as source_seq,
    _commit_ts::timestamp_ntz  as commit_ts,
    _loaded_at::timestamp_ntz  as loaded_at
from {{ source('s4_frozen', 'orders_cdc') }}
