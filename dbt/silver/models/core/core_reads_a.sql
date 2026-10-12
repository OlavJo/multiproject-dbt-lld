-- Core's first read of its upstream units: what a long Core build reads early
select count(*)                                     as orders,
       sum(amount)                                  as amount,
       (select count(*) from {{ ref('erp_accounts') }}) as accounts,
       (select count(*) from {{ ref('crm_contacts') }}) as contacts
from {{ ref('erp_orders_current') }}
