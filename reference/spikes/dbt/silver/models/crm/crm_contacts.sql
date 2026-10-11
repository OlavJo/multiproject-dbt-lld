{{ config(materialized='table', grants={'select': ['ANALYST_TIER1']}) }}

select contact_id, full_name, segment, loaded_at
from {{ ref('stg_crm__contacts') }}
