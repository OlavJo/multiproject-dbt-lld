-- S6: this comment is the change that state:modified must detect (the body checksum changes)
-- Base model: 1:1 with the source table, cast and renamed, over the frozen input
select
    account_id::number(38, 0)     as account_id,
    lower(email)::varchar         as email,
    account_name::varchar         as account_name,
    _loaded_at::timestamp_ntz     as loaded_at
from {{ source('erp_frozen', 'accounts') }}
