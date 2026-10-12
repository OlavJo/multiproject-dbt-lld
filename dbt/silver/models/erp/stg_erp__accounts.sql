-- Base model: 1:1 with the frozen input, cast and renamed (SLD 6.2)
select
    account_id::number(38, 0)     as account_id,
    lower(email)::varchar         as email,
    account_name::varchar         as account_name,
    _loaded_at::timestamp_ntz     as loaded_at
from {{ source('erp_frozen', 'accounts') }}
