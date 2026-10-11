-- =============================================================================
-- Spike S8, part 5: follow-ups to s08c and s08d
--
--   A  What did the two executions that shared a target path log? (s08c's output probes
--      failed on a boolean concatenation; the task runs are still readable.)
--   B  Does CREATE OR REPLACE DBT PROJECT make earlier executions' artifacts
--      unreachable? Hypothesis from s08c: the canonical-state query ids of executions
--      that ran before a redeploy cannot be located afterwards. Test: locate a known id
--      from before s08d's redeploy (expected: denied), one from after it (expected:
--      found), redeploy, then the "after" id again (expected: denied).
--   C  Did the redeploy in s08d overlap the running publication? Statement times from
--      query history (ACCOUNTADMIN).
--   D  Does CREATE OR REPLACE DBT PROJECT drop the unit roles' grants? Redeploy WITHOUT
--      re-granting; try to execute as a unit role; then restore the grants.
--
-- The ids in B are from evidence/S8b_run2_20261006.csv (before s08d) and
-- evidence/S8d_20261007.csv (after it).
-- Run as: SVC_SILVER_ERP, SILVER_STEWARD, ACCOUNTADMIN (switches itself). About 3 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set git_ref = 'main';

-- A: output of the two shared-path executions ------------------------------------------------
use role svc_silver_erp;
set qid_e = (select query_id from table(silver.information_schema.task_history(task_name => 'S8_SHARED_ERP', result_limit => 1)));
set sql_e = (select 'select ''success='' || $1::varchar || ''; unable_partial='' || contains($3, ''Unable to do partial parsing'')::varchar || ''; writeback=['' || nvl(array_to_string(regexp_substr_all($3, ''[^\n]*[Ww]riteback[^\n]*''), '' | ''), ''-'') || '']'' from table(result_scan(''' || $qid_e || '''))');
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.A1', 'ERP shared-path execution: success, partial-parse warning, writeback lines', $sql_e, null);
use role svc_silver_crm;
set qid_c = (select query_id from table(silver.information_schema.task_history(task_name => 'S8_SHARED_CRM', result_limit => 1)));
set sql_c = (select 'select ''success='' || $1::varchar || ''; unable_partial='' || contains($3, ''Unable to do partial parsing'')::varchar || ''; writeback=['' || nvl(array_to_string(regexp_substr_all($3, ''[^\n]*[Ww]riteback[^\n]*''), '' | ''), ''-'') || '']'' from table(result_scan(''' || $qid_c || '''))');
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.A2', 'CRM shared-path execution: success, partial-parse warning, writeback lines', $sql_c, null);

-- B: canonical state across a redeploy -----------------------------------------------------------------
use role svc_silver_erp;
set sql_before = (select 'select system$locate_dbt_artifacts(''01c78f19-0004-2170-0003-5b0a0004045a'')');   -- ERP canonical, before s08d's redeploy
set sql_after  = (select 'select system$locate_dbt_artifacts(''01c78f28-0004-216f-0003-5b0a000524fe'')');   -- last successful run, after it
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.B1', 'Locate an execution from BEFORE the s08d redeploy (hypothesis: denied)', $sql_before, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.B2', 'Locate an execution from AFTER the s08d redeploy (expected: found)', $sql_after, null);

-- Redeploy again, then the same two
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set create_sql = (select 'create or replace dbt project silver.ops.silver_layer from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver'' dbt_version = ''1.12.3''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.B3', 'Redeploy the project object (CREATE OR REPLACE) without re-granting', $create_sql, '!ERROR:%');

-- D: grants after the redeploy (nothing re-granted yet)
show grants on dbt project silver.ops.silver_layer;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8e.D2', 'Grants on the project object after CREATE OR REPLACE and no re-grant', 'show grants on dbt project', null,
         'rows=' || count(*) || '; grantees=' || nvl(listagg("grantee_name" || ':' || "privilege", ', '), '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), array_agg(object_construct(*))
  from table(result_scan(last_query_id()));

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.D3', 'A unit role executes the redeployed object WITHOUT a re-grant (does it still have USAGE?)',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --target-path target/canonical --log-path logs/canonical'$$, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.B4', 'Locate the "after" execution again, now after a second redeploy (hypothesis: denied)', $sql_after, null);

-- Restore grants
use role silver_steward;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_erp;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_crm;
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8e.D4', 'After re-granting: a unit role executes the object again',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --target-path target/canonical --log-path logs/canonical'$$, '!ERROR:%');

-- C: did s08d's redeploy overlap its publication? Statement times from query history ----------------------
use role accountadmin;
select start_time, end_time, role_name, left(query_text, 110) as query_text
from table(spike_lab.information_schema.query_history(end_time_range_start => dateadd(minute, -240, current_timestamp()), result_limit => 10000))
where (query_text ilike 'create or replace dbt project%' or query_text ilike 'execute dbt project%')
  and start_time between dateadd(minute, -200, current_timestamp()) and dateadd(minute, -3, current_timestamp())
order by start_time;

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
