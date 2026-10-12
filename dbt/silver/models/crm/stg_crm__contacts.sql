select
    contact_id::number(38, 0)     as contact_id,
    full_name::varchar            as full_name,
    segment::varchar              as segment,
    _loaded_at::timestamp_ntz     as loaded_at
from {{ source('crm_frozen', 'contacts') }}
