-- Spike S10: the same read, a minute later in the same build (a long Core build reads several models
-- of its upstream units over minutes). If an upstream unit publishes in between and the reads go to
-- the published schemas, this model and core_orders_a see different versions.
{{ config(pre_hook="select system$wait(" ~ var('core_wait_seconds', 70) ~ ")") }}
-- depends_on: {{ ref('core_orders_a') }}
select count(*) as orders, sum(amount) as amount,
       (select count(*) from {{ ref('crm_contacts') }}) as contacts,
       (select count(*) from {{ ref('erp_accounts') }}) as accounts
from {{ ref('erp_orders_current') }}
