select
    customer_id::number(38, 0) as customer_id,
    name::varchar              as name,
    tier::varchar              as tier
from {{ source('s4_frozen', 'customers') }}
