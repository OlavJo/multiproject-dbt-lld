-- =============================================================================
-- Spike S8, part 4: a deployment of the project object while a unit is running
-- (SLD 14 S8: "effect of a deployment during running units"; SLD 12.2 DEPLOYED)
--
-- The ERP task starts a publication (about 50 s). About 15 s in, the steward redeploys
-- the project object (CREATE OR REPLACE DBT PROJECT from Git, as setup/07 does). Does the
-- running execution complete, fail, or read the new code? Then: is the object usable
-- afterwards, and what did the redeploy do to the unit roles' grants, the live version's
-- artifacts, and run control?
-- The redeployed code is identical (same Git ref), so any failure is the redeploy's.
-- Requires s08b_tasks.sql (the task) and setup/07's Git ref. Takes about 4 minutes.
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, SILVER_STEWARD (switches itself).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set git_ref = 'main';

use role platform_ingest;
call raw.control.land_batch('ERP', false);
set t_start = (select sysdate());

use role svc_silver_erp;
execute task silver.ops.s8_task_erp;
select system$wait(15);

-- Redeploy while the run is in progress
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set create_sql = (select 'create or replace dbt project silver.ops.silver_layer from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver'' dbt_version = ''1.12.3''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.01', 'Redeploy the project object while the ERP run is in progress', $create_sql, '!ERROR:%');
set t_deployed = (select sysdate());
grant usage on dbt project silver.ops.silver_layer to role svc_silver_erp;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_crm;

select system$wait(90);

-- What happened to the run that was in progress
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.02', 'Timeline of the run (events since the start)',
  'select listagg(unit || '' '' || event_type || '' '' || to_varchar(event_ts, ''HH24:MI:SS.FF1''), '' | '') within group (order by event_ts) from analytics_ops.control.publish_log where unit = ''silver.erp'' and event_ts > ''' || $t_start || '''::timestamp_ntz', null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.03', 'Outcome of the run in progress (PUBLISHED, or the failure text)',
  'select nvl(max(iff(event_type = ''PUBLISHED'', ''PUBLISHED'', null)), nvl(max(left(detail:exception::varchar, 600)), ''no terminal event'')) from analytics_ops.control.publish_log where unit = ''silver.erp'' and event_type in (''PUBLISHED'', ''FAILED'') and event_ts > ''' || $t_start || '''::timestamp_ntz', null);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.04', 'Task run of the ERP task: state and error',
  $$select state || ' | ' || nvl(error_message, '-') from table(silver.information_schema.task_history(task_name => 'S8_TASK_ERP', result_limit => 1))$$, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.05', 'Lease released after the run',
  $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');

-- Is the object usable afterwards, and does it start from scratch (no written-back state)?
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.06', 'A new batch publishes on the redeployed object',
  $$call silver.ops.publish_unit('silver.erp')$$, 'SKIPPED%');
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.07', 'After a new batch: publishes on the redeployed object',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S8', 'S8d.08', 'Last successful run target after the redeploy and the new publication',
  $$select system$dbt_get_last_successful_run_target('silver.ops.silver_layer')$$, null);

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
