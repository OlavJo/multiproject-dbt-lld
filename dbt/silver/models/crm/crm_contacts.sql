{{ config(materialized='table') }}

select contact_id, full_name, segment, loaded_at
from {{ ref('stg_crm__contacts') }}
