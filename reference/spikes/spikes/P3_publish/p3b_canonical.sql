-- =============================================================================
-- Phase 2: canonical state after publication (SLD 3.2 step 1 to 3)
-- p3_publish.sql P3.A4 showed the canonical compile ran (WRITEBACK = FALSE is
-- accepted; its query id was recorded) but the procedure then read its result
-- from the wrong statement ("Boolean value '<query id>' is not recognized"). That
-- is fixed in setup/08 (result_scan of the saved query id). This script, after
-- re-running setup/08:
--   1  publishes again and checks the canonical compile is recorded as ok
--   2  asks Snowflake for the artifacts of that query id
--      (SYSTEM$LOCATE_DBT_ARTIFACTS), as CI would, to be used for state:modified
--      and --defer; the result of this call is recorded whole
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP (the script switches).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role platform_ingest;
call raw.control.land_batch('ERP', false);

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3b.01', 'Publish after the fix',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'P3', 'P3b.02', 'Canonical compile recorded as ok in the PUBLISHED event',
  $$select detail:canonical_ok::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1$$,
  'true');
call spike_lab.evidence.probe($run_id, 'P3', 'P3b.03', 'State query id recorded',
  $$select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1$$,
  null);

-- CI's view of the canonical state: locate the artifacts of that execution
set qid = (select detail:state_query_id::varchar from analytics_ops.control.publish_log
           where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
set locate_sql = (select 'select system$locate_dbt_artifacts(''' || $qid || ''')');
call spike_lab.evidence.probe($run_id, 'P3', 'P3b.04', 'SYSTEM$LOCATE_DBT_ARTIFACTS on the canonical query id',
  $locate_sql, null);

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
