-- Spike S10: the first read of the upstream units' published data
select count(*) as orders, sum(amount) as amount,
       (select count(*) from {{ ref('crm_contacts') }}) as contacts,
       (select count(*) from {{ ref('erp_accounts') }}) as accounts
from {{ ref('erp_orders_current') }}
