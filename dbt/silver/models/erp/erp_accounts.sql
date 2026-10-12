{{ config(materialized='table') }}

select account_id, email, account_name, loaded_at
from {{ ref('stg_erp__accounts') }}
