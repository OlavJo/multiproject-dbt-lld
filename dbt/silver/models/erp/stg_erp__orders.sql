-- Base model: 1:1 with the frozen input; _seq is the source ordering column (SLD 4.1)
select
    order_id::number(38, 0)       as order_id,
    account_id::number(38, 0)     as account_id,
    status::varchar               as status,
    amount::number(18, 2)         as amount,
    _seq::number(38, 0)           as source_seq,
    _loaded_at::timestamp_ntz     as loaded_at
from {{ source('erp_frozen', 'orders') }}
