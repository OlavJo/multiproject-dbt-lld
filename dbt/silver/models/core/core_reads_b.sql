-- The same read, later in the same build (demo pause, var core_read_pause_seconds). Without input
-- clones an upstream publication in between makes the two reads disagree (spike S10, run 2); with
-- them both read the clone taken at the gate. The same_rows test detects a disagreement.
{{ config(pre_hook="select system$wait(" ~ var('core_read_pause_seconds', 0) ~ ")") }}
-- depends_on: {{ ref('core_reads_a') }}
select count(*)                                     as orders,
       sum(amount)                                  as amount,
       (select count(*) from {{ ref('erp_accounts') }}) as accounts,
       (select count(*) from {{ ref('crm_contacts') }}) as contacts
from {{ ref('erp_orders_current') }}
