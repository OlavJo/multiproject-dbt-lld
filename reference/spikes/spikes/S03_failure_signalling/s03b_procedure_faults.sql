-- =============================================================================
-- Spike S3, part 2: procedure-level cases B2, B3 and the closing checks
-- The first run of s03_failure_signalling.sql stopped at B2 because
-- "ALTER TABLE ... RENAME TO orders_x" resolved the new name against the session's
-- current database, and the session has none (observed): a rename target must be
-- qualified. Nothing had been renamed; the raw tables were intact and B1 had
-- recovered. Parts A and B1 of the first run stand.
-- This script re-establishes the baseline count and runs the rest.
-- Requires the helper from s03_failure_signalling.sql (not used here).
-- Run as: SVC_SILVER_ERP, PLATFORM_INGEST, ANALYST_TIER1, SILVER_STEWARD (switches itself).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role svc_silver_erp;
set n0 = (select count(*) from silver.erp.erp_orders_current);
set q_unchanged = (select 'select iff(count(*) = ' || $n0 || ', ''UNCHANGED'', ''CHANGED'') from silver.erp.erp_orders_current');

-- B2: the freeze fails: a raw table is missing
use role platform_ingest;
alter table raw.erp.orders rename to raw.erp.orders_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B20', 'B2: a raw table is missing: the procedure reports the freeze failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:freeze');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B21', 'B2: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B22', 'B2: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B23', 'B2: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B24', 'B2: FAILED event: exception text and STDOUT tail',
  $$select nvl(detail:exception::varchar, '<null>') || ' | ' || left(nvl(detail:stdout_tail::varchar, '<null>'), 1200) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders_x rename to raw.erp.orders;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B25', 'B2: after the table is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B3: the build fails: a raw column is renamed (schema drift)
use role platform_ingest;
alter table raw.erp.orders rename column status to status_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B30', 'B3: a raw column is renamed: the procedure reports the build failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:build');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B31', 'B3: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B32', 'B3: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B33', 'B3: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B34', 'B3: FAILED event: STDOUT tail (does it name the model that failed?)',
  $$select left(detail:stdout_tail::varchar, 1500) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders rename column status_x to status;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B35', 'B3: after the column is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B4: state after the failures ---------------------------------------------------------------
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B40', 'Run control: events of the three failed runs and the recoveries',
  $$select listagg(event_type || ':' || nvl(detail:stage::varchar, nvl(detail:reason::varchar, '')), ', ') within group (order by event_ts) from (select * from analytics_ops.control.publish_log where unit = 'silver.erp' order by event_ts desc limit 24)$$, null);
use role silver_steward;   -- the stale-run view is a steward view (unit roles have no grant on it)
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B41', 'Run control: no stale STARTED after the failures',
  $$select count(*) from analytics_ops.control.unit_stale where unit = 'silver.erp' and is_stale$$, '0');

-- Evidence ---------------------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
