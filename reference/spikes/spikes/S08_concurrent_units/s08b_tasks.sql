-- =============================================================================
-- Spike S8, part 2: two units as two scheduled tasks, each owned by its unit role
-- Run 1 (s08_concurrent_units.sql, Part A) called both units from one session as
-- SYSADMIN. Both failed at the freeze: the procedure is caller's-rights, so the
-- build schema it created was owned by SYSADMIN, and the dbt execution (profile
-- role SVC_SILVER_ERP) had no privilege on it. A unit must run as its own role.
-- This is the production shape (SLD 12.7): one task per unit, each owned by the unit's
-- service role, running at the same moment in separate sessions.
--
--   Setup  EXECUTE TASK on account and CREATE TASK on silver.ops for the unit roles;
--          one task per unit (no schedule; started by EXECUTE TASK)
--   A      two new batches land; both tasks started within a second; wait; both units
--          published, overlapping, with their own data and canonical state ids
--   B      query history: most EXECUTE DBT PROJECT statements in progress together
--   C      task history (state and errors of the two task runs)
--   D      SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET and LOCATE_DBT_ARTIFACTS per unit
-- Requires setup/08 (re-run: the freeze failure classification changed).
-- Run as: ACCOUNTADMIN, SILVER_STEWARD, PLATFORM_INGEST, SVC_SILVER_ERP, SVC_SILVER_CRM
-- (the script switches roles itself). Takes about 5 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set t0 = (select sysdate());

-- Setup ---------------------------------------------------------------------------------
use role accountadmin;
grant execute task on account to role svc_silver_erp;
grant execute task on account to role svc_silver_crm;
use role silver_steward;
grant create task on schema silver.ops to role svc_silver_erp;
grant create task on schema silver.ops to role svc_silver_crm;

-- Leftover build schemas from a failed run can belong to another role (run 1 created them
-- as SYSADMIN) and block CREATE OR REPLACE SCHEMA by the unit role: remove them first.
use role sysadmin;
drop schema if exists silver.erp__build;
drop schema if exists silver.crm__build;

use role svc_silver_erp;
create or replace task silver.ops.s8_task_erp
  warehouse = spike_wh
  as call silver.ops.publish_unit('silver.erp');
use role svc_silver_crm;
create or replace task silver.ops.s8_task_crm
  warehouse = spike_wh
  as call silver.ops.publish_unit('silver.crm');

-- A: new data, then both tasks at the same moment --------------------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);
set t_start = (select sysdate());

use role svc_silver_erp;
execute task silver.ops.s8_task_erp;
use role svc_silver_crm;
execute task silver.ops.s8_task_crm;

select system$wait(170);

use role silver_steward;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A1', 'Both units logged PUBLISHED since the tasks started',
  'select count(distinct unit) from analytics_ops.control.publish_log where event_type = ''PUBLISHED'' and unit in (''silver.erp'', ''silver.crm'') and event_ts > ''' || $t_start || '''::timestamp_ntz', '2');
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A2', 'Their runs overlapped in time (STARTED of each before PUBLISHED of the other)',
  'with e as (select unit, max(iff(event_type = ''STARTED'', event_ts, null)) as s, max(iff(event_type = ''PUBLISHED'', event_ts, null)) as p from analytics_ops.control.publish_log where unit in (''silver.erp'', ''silver.crm'') and event_ts > ''' || $t_start || '''::timestamp_ntz group by unit) select iff((select s from e where unit = ''silver.erp'') < (select p from e where unit = ''silver.crm'') and (select s from e where unit = ''silver.crm'') < (select p from e where unit = ''silver.erp''), ''OVERLAP'', ''SERIAL'')',
  'OVERLAP');
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A3', 'Timeline of the two runs',
  'select listagg(unit || '' '' || event_type || '' '' || to_varchar(event_ts, ''HH24:MI:SS.FF1''), '' | '') within group (order by event_ts) from analytics_ops.control.publish_log where unit in (''silver.erp'', ''silver.crm'') and event_ts > ''' || $t_start || '''::timestamp_ntz', null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A4', 'Any FAILED event in the two runs (exception text if so)',
  'select nvl(listagg(unit || '': '' || left(detail:exception::varchar, 400), '' | ''), ''none'') from analytics_ops.control.publish_log where event_type = ''FAILED'' and unit in (''silver.erp'', ''silver.crm'') and event_ts > ''' || $t_start || '''::timestamp_ntz', 'none');
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A5', 'Leases of both units are free',
  $$select count(*) from analytics_ops.control.unit_lease where unit in ('silver.erp', 'silver.crm') and run_id is not null$$, '0');
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A6a', 'ERP unit data: current orders', $$select count(*) from silver.erp.erp_orders_current$$, null);
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A6b', 'CRM unit data: contacts', $$select count(*) from silver.crm.crm_contacts$$, null);
use role silver_steward;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.A7', 'The two PUBLISHED events carry distinct canonical state query ids, both compiled ok',
  'select count(distinct detail:state_query_id::varchar) || '' ids, ok='' || count_if(detail:canonical_ok::boolean) from analytics_ops.control.publish_log where event_type = ''PUBLISHED'' and unit in (''silver.erp'', ''silver.crm'') and event_ts > ''' || $t_start || '''::timestamp_ntz', '2 ids, ok=2');

-- B: concurrency in query history ---------------------------------------------------------------
use role accountadmin;
insert into spike_lab.evidence.observation
  with q as (
    select query_id, start_time, end_time
    from table(spike_lab.information_schema.query_history(
           end_time_range_start => dateadd(minute, -15, current_timestamp()), result_limit => 10000))
    where query_text ilike 'execute dbt project%'
      and start_time >= dateadd(minute, -10, current_timestamp())
  ),
  o as (
    select a.query_id, count(*) as overlapping
    from q a join q b on b.start_time < a.end_time and b.end_time > a.start_time
    group by a.query_id
  )
  select $run_id, 'S8', 'S8b.B1', 'EXECUTE DBT PROJECT statements in the last 10 minutes and the most in progress together',
         'information_schema.query_history', null,
         'statements=' || (select count(*) from q) || '; max_concurrent=' || (select max(overlapping) from o),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null;

-- C: task history ------------------------------------------------------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.C1', 'Task run of the ERP task (state, error, scheduled and completed time)',
  $$select state || ' | ' || nvl(error_message, '-') || ' | ' || to_varchar(scheduled_time, 'HH24:MI:SS') || ' to ' || nvl(to_varchar(completed_time, 'HH24:MI:SS'), '?') from table(silver.information_schema.task_history(task_name => 'S8_TASK_ERP', result_limit => 1))$$, 'SUCCEEDED%');
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.C2', 'Task run of the CRM task (state, error, scheduled and completed time)',
  $$select state || ' | ' || nvl(error_message, '-') || ' | ' || to_varchar(scheduled_time, 'HH24:MI:SS') || ' to ' || nvl(to_varchar(completed_time, 'HH24:MI:SS'), '?') from table(silver.information_schema.task_history(task_name => 'S8_TASK_CRM', result_limit => 1))$$, 'SUCCEEDED%');

-- D: the object's state functions with two units on it --------------------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.D1', 'SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET after the two runs (which unit does it point at?)',
  $$select system$dbt_get_last_successful_run_target('silver.ops.silver_layer')$$, null);
set qid_erp = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
set qid_crm = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.crm' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
set sql_erp = (select 'select system$locate_dbt_artifacts(''' || $qid_erp || ''')');
set sql_crm = (select 'select system$locate_dbt_artifacts(''' || $qid_crm || ''')');
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.D2', 'LOCATE_DBT_ARTIFACTS for the ERP canonical query id', $sql_erp, null);
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.D3', 'LOCATE_DBT_ARTIFACTS for the CRM canonical query id, called by the CRM role', $sql_crm, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8b.D4', 'LOCATE_DBT_ARTIFACTS for the ERP canonical query id, called by the CRM role (run 1: the other role was denied)', $sql_erp, null);

-- Evidence ---------------------------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
