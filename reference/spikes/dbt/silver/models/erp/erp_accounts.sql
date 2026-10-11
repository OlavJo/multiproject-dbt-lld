{{ config(materialized='table', grants={'select': ['ANALYST_TIER1']}) }}

select account_id, email, account_name, loaded_at
from {{ ref('stg_erp__accounts') }}
