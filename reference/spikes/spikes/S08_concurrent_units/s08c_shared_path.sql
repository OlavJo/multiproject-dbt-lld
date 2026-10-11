-- =============================================================================
-- Spike S8, part 3: two executions on ONE target path; and the open LOCATE denial
-- (s08_concurrent_units.sql Part E failed in the helper, not in the platform:
--  LAST_QUERY_ID() is session-wide, so two ASYNC children of one session read each
--  other's result. Here the two executions are two tasks, one session each.)
--
--   E  two tasks, one per unit role, run `compile` with the SAME --target-path and
--      --log-path at the same moment (SLD 3.1: writeback is disabled for the execution
--      when paths overlap, or the executions must use distinct paths). Observe whether
--      both succeed and what their output says about writeback and partial parsing.
--   D5 the open question from run 2: can the ERP role locate the CRM canonical
--      execution (it was denied once)?
-- Requires s08b_tasks.sql (the grants for tasks) and a published CRM unit.
-- Run as: SVC_SILVER_ERP, SVC_SILVER_CRM, SILVER_STEWARD (switches itself). About 3 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- E: two tasks, one shared target path ------------------------------------------------------
use role svc_silver_erp;
create or replace task silver.ops.s8_shared_erp
  warehouse = spike_wh
  as execute dbt project silver.ops.silver_layer
       args = 'compile --target prod_erp --vars "{publish_unit: erp}" --target-path target/shared --log-path logs/shared';
use role svc_silver_crm;
create or replace task silver.ops.s8_shared_crm
  warehouse = spike_wh
  as execute dbt project silver.ops.silver_layer
       args = 'compile --target prod_crm --vars "{publish_unit: crm}" --target-path target/shared --log-path logs/shared';

use role svc_silver_erp;
execute task silver.ops.s8_shared_erp;
use role svc_silver_crm;
execute task silver.ops.s8_shared_crm;
select system$wait(75);

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.E1', 'ERP task, shared target path: state, error, times',
  $$select state || ' | ' || nvl(error_message, '-') || ' | ' || to_varchar(scheduled_time, 'HH24:MI:SS') || ' to ' || nvl(to_varchar(completed_time, 'HH24:MI:SS'), '?') from table(silver.information_schema.task_history(task_name => 'S8_SHARED_ERP', result_limit => 1))$$, null);
set qid_e = (select query_id from table(silver.information_schema.task_history(task_name => 'S8_SHARED_ERP', result_limit => 1)));
set sql_e = (select 'select ''success='' || $1::varchar || ''; unable_partial='' || contains($3, ''Unable to do partial parsing'')::varchar || ''; writeback=['' || nvl(array_to_string(regexp_substr_all($3, ''[^\n]*[Ww]riteback[^\n]*''), '' | ''), ''-'') || '']'' from table(result_scan(''' || $qid_e || '''))');
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.E1b', 'ERP task output: success flag, partial-parse warning, writeback lines', $sql_e, null);

use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.E2', 'CRM task, shared target path: state, error, times',
  $$select state || ' | ' || nvl(error_message, '-') || ' | ' || to_varchar(scheduled_time, 'HH24:MI:SS') || ' to ' || nvl(to_varchar(completed_time, 'HH24:MI:SS'), '?') from table(silver.information_schema.task_history(task_name => 'S8_SHARED_CRM', result_limit => 1))$$, null);
set qid_c = (select query_id from table(silver.information_schema.task_history(task_name => 'S8_SHARED_CRM', result_limit => 1)));
set sql_c = (select 'select ''success='' || $1::varchar || ''; unable_partial='' || contains($3, ''Unable to do partial parsing'')::varchar || ''; writeback=['' || nvl(array_to_string(regexp_substr_all($3, ''[^\n]*[Ww]riteback[^\n]*''), '' | ''), ''-'') || '']'' from table(result_scan(''' || $qid_c || '''))');
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.E2b', 'CRM task output: success flag, partial-parse warning, writeback lines', $sql_c, null);

-- A third execution afterwards, same shared path, alone: is the path still usable?
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.E3', 'A later single execution on the shared target path',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --vars "{publish_unit: erp}" --target-path target/shared --log-path logs/shared'$$, '!ERROR:%');

-- D5: the open LOCATE question ----------------------------------------------------------------
set qid_crm = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.crm' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
set sql_crm = (select 'select system$locate_dbt_artifacts(''' || $qid_crm || ''')');
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.D5', 'ERP role locates the latest CRM canonical execution (denied once, run 2)', $sql_crm, null);
set qid_old = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.crm' and event_type = 'PUBLISHED' order by event_ts asc limit 1);
set sql_old = (select 'select system$locate_dbt_artifacts(''' || $qid_old || ''')');
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.D6', 'ERP role locates the OLDEST CRM canonical execution (the one denied in run 2 was an older one)', $sql_old, null);
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S8', 'S8c.D7', 'CRM role locates its own OLDEST canonical execution', $sql_old, null);

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
