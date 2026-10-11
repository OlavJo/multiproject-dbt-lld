-- =============================================================================
-- Spike S12.34: direct evidence that the race contenders ran concurrently
-- Run after s12_unit_lease.sql, within a few hours, as ACCOUNTADMIN.
--
-- Counts the lease UPDATE statements in query history (expected: 100 race
-- contenders + 5 acquire calls in Parts A and B = 105) and the maximum number
-- of them in progress at the same moment (including time waiting on locks).
-- INFORMATION_SCHEMA table functions need a database; SPIKE_LAB is used only
-- to resolve the function, the history covers the whole account.
-- =============================================================================

use role accountadmin;
use secondary roles none;
use warehouse spike_wh;

with q as (
  select query_id, start_time, end_time
  from table(spike_lab.information_schema.query_history(
         end_time_range_start => dateadd(hour, -3, current_timestamp()),
         result_limit => 10000))
  where query_text ilike 'update analytics_ops.control.unit_lease l%'
)
select count(*)          as lease_updates,
       max(overlapping)  as max_concurrent_updates
from (
  select a.query_id, count(*) as overlapping
  from q a
  join q b on b.start_time < a.end_time and b.end_time > a.start_time
  group by a.query_id
);
