-- =============================================================================
-- Spike S3, part 3: attribution of failures (re-run of B1 to B3 after setup/08 update)
-- S3 showed that EXECUTE DBT PROJECT RAISES on a dbt failure (it does not return
-- FALSE), with dbt's output in the error text and a query id for
-- SYSTEM$GET_DBT_LOG. setup/08 now (a) classifies the failure from that text
-- (a failing source test or the freeze: source; any other test or model: transform),
-- (b) fetches the dbt log by that query id into the FAILED event.
-- This script repeats the three faults and checks stage, class and the log.
-- Expected: B1 build / source; B2 freeze / source; B3 build / transform.
-- Requires setup/08 re-run, and the helper is not needed.
-- Run as: SVC_SILVER_ERP, PLATFORM_INGEST, ANALYST_TIER1, SILVER_STEWARD (switches itself).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.00', 'Baseline publish through the procedure', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
set n0 = (select count(*) from silver.erp.erp_orders_current);
set q_unchanged = (select 'select iff(count(*) = ' || $n0 || ', ''UNCHANGED'', ''CHANGED'') from silver.erp.erp_orders_current');

-- B1: a source test fails: a row with a null key lands (and a new landing-complete record)
use role platform_ingest;
insert into raw.erp.orders (order_id, account_id, status, amount, _seq) values (null, 1, 'BAD', 1, 99999);
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B10', 'B1: source test fails: the procedure reports the build failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:build');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B11', 'B1: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B12', 'B1: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B13', 'B1: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, 'build / source');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B14', 'B1: FAILED event: exception text',
  $$select detail:exception::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B15', 'B1: FAILED event: STDOUT tail (does it name the failing source test?)',
  $$select left(detail:stdout_tail::varchar, 1500) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B16', 'B1: consumer still reads masked PII from the last good version',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
use role platform_ingest;
delete from raw.erp.orders where order_id is null;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B17', 'B1: after the bad row is removed and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B2: the freeze fails: a raw table is missing
use role platform_ingest;
alter table raw.erp.orders rename to raw.erp.orders_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B20', 'B2: a raw table is missing: the procedure reports the freeze failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:freeze');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B21', 'B2: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B22', 'B2: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B23', 'B2: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, 'freeze / source');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B24', 'B2: FAILED event: exception text and STDOUT tail',
  $$select nvl(detail:exception::varchar, '<null>') || ' | ' || left(nvl(detail:stdout_tail::varchar, '<null>'), 1200) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders_x rename to raw.erp.orders;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B25', 'B2: after the table is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B3: the build fails: a raw column is renamed (schema drift)
use role platform_ingest;
alter table raw.erp.orders rename column status to status_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B30', 'B3: a raw column is renamed: the procedure reports the build failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:build');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B31', 'B3: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B32', 'B3: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B33', 'B3: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, 'build / transform');
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B34', 'B3: FAILED event: STDOUT tail (does it name the model that failed?)',
  $$select left(detail:stdout_tail::varchar, 1500) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders rename column status_x to status;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.B35', 'B3: after the column is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');


-- Attribution summary: the last three FAILED events -------------------------------------
call spike_lab.evidence.probe($run_id, 'S3', 'S3c.90', 'FAILED events: stage / class / dbt log fetched (latest three, oldest first)',
  $$select listagg(detail:stage::varchar || ' / ' || detail:failure_class::varchar || ' / ' || nvl(detail:dbt_log_fetched::varchar, 'null'), ' | ') within group (order by event_ts) from (select * from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 3)$$,
  'build / source / true | freeze / source / % | build / transform / true');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
