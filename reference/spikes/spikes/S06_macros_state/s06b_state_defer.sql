-- =============================================================================
-- Spike S6, part B: state:modified and --defer against the canonical state, in the CI target
-- Run after s06a_dev_and_baseline.sql (it recorded the canonical state Q0 of the deployed code)
-- and after the S6 change is on main: stg_erp__accounts.sql has a new leading comment (a body
-- change, nothing else) and profiles.yml has the ci target.
--
--   1  deploy that code in place (ADD VERSION, S8g): the object keeps its grants and Q0
--   2  how to hand the canonical state to dbt. Run 1 showed a stage path given to --state is not
--      read ("Got a state selector method, but no comparison manifest"). Snowflake mounts state
--      through an IMPORTS clause: IMPORTS = ('<path>' AS 'state') mounts it at ./imports/state and
--      --state ./imports/state points dbt at it. Candidate paths are tried and failures recorded
--   3  state:modified in the prod target: only the changed model
--   4  state:modified in the CI target: schemas differ, so every node differs in "relation"?
--      state:modified.body picks the real change
--   5  CI slim build: freeze into ci_erp, then build only what the change touches (plus
--      downstream) with --defer, unselected parents read from the published schema; a negative
--      control without --defer; the published schema untouched
-- Run 2 (this version): after the freeze macro fix (it now creates the dev and CI schemas) and with the
-- IMPORTS syntax. Q0 is unchanged by run 1 (nothing was published since).
-- Run as: SILVER_STEWARD, SVC_SILVER_ERP (the CI role in this spike). About 6 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set git_ref = 'main';

-- Helper: find a form of --state that works -------------------------------------------------------------
use role sysadmin;
create or replace procedure spike_lab.evidence.s6_find_state_path(p_run_id varchar, p_p0 varchar, p_last varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_forms array;
  v_form  varchar;
  v_sql   varchar;
  v_err   varchar;
begin
  v_forms := array_construct(:p_p0, :p_p0 || 'target/', :p_last);
  for i in 0 to 2 do
    v_form := get(:v_forms, :i)::varchar;
    v_sql := 'execute dbt project silver.ops.silver_layer args = ''list --select state:modified --resource-type model --state ./imports/state'
          || ' --target prod_erp --target-path target/s6state --log-path logs/s6state'' imports = (''' || v_form || ''' as ''state'')';
    begin
      execute immediate :v_sql;
      insert into spike_lab.evidence.observation
        select :p_run_id, 'S6', 'S6b.state_form_' || :i, 'The imported state WORKS: ' || :v_form, :v_sql, null, 'success', 'INFO',
               current_role(), current_secondary_roles(), sysdate(), current_version(), null;
      return v_form;
    exception
      when other then
        v_err := sqlerrm;
        insert into spike_lab.evidence.observation
          select :p_run_id, 'S6', 'S6b.state_form_' || :i, 'The imported state fails: ' || :v_form, :v_sql, null, 'ERROR: ' || left(:v_err, 800), 'INFO',
                 current_role(), current_secondary_roles(), sysdate(), current_version(), null;
    end;
  end for;
  return 'NONE';
end;
$$;

-- Helper: one EXECUTE DBT PROJECT call with state imported, recorded whole (stdout tail in DETAIL)
create or replace procedure spike_lab.evidence.run_dbt_imp(
    p_run_id varchar, p_case varchar, p_desc varchar, p_args varchar, p_import varchar, p_expect_success boolean)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_sql    varchar;
  v_ok     boolean;
  v_out    varchar;
  v_raised boolean default false;
  v_err    varchar;
  v_qid    varchar;
begin
  v_sql := 'execute dbt project silver.ops.silver_layer args = ''' || replace(p_args, '''', '''''') || ''' imports = (''' || p_import || ''' as ''state'')';
  begin
    execute immediate :v_sql;
    select last_query_id() into :v_qid;
    select $1::boolean, $3::varchar into :v_ok, :v_out from table(result_scan(:v_qid));
  exception
    when other then
      v_raised := true;
      v_err := sqlerrm;
  end;
  insert into spike_lab.evidence.observation
    select :p_run_id, 'S6', :p_case, :p_desc, :v_sql, iff(:p_expect_success, 'success=true', 'raises'),
           iff(:v_raised, 'RAISED: ' || left(:v_err, 700), 'success=' || nvl(:v_ok::varchar, 'null')),
           iff(:v_raised <> :p_expect_success, 'PASS', 'FAIL'),
           current_role(), current_secondary_roles(), sysdate(), current_version(),
           object_construct('query_id', :v_qid, 'raised', :v_raised, 'error', left(:v_err, 1500), 'stdout_tail', right(:v_out, 2500));
  return iff(:v_raised, 'RAISED', 'success=' || nvl(:v_ok::varchar, 'null'));
end;
$$;
grant usage on procedure spike_lab.evidence.run_dbt_imp(varchar, varchar, varchar, varchar, varchar, boolean) to role svc_silver_erp;
grant usage on procedure spike_lab.evidence.s6_find_state_path(varchar, varchar, varchar) to role svc_silver_erp;

-- 1: deploy the changed code in place -------------------------------------------------------------------
use role svc_silver_erp;
set base_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');
set q0 = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.00', 'Q0, the canonical state recorded before the change', 'select ''' || $q0 || '''', null);
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set sql_add = (select 'alter dbt project silver.ops.silver_layer add version from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver''');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.01', 'Deploy the changed code in place (ADD VERSION)', $sql_add, '!ERROR:%');

-- 2: how to point --state at the canonical state ---------------------------------------------------------
use role svc_silver_erp;
set sql_locate = (select 'select system$locate_dbt_artifacts(''' || $q0 || ''')');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.02', 'Q0 still locates after the deployment', $sql_locate, null);
set p0 = 'snow://dbt/SILVER.OPS.SILVER_LAYER/results/query_id_' || $q0 || '/';   -- the form LOCATE returned (S6b.02 confirms it locates)
set plast = (select system$dbt_get_last_successful_run_target('silver.ops.silver_layer'));
call spike_lab.evidence.s6_find_state_path($run_id, $p0, $plast);
set state_form = (select $1 from table(result_scan(last_query_id())));
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.03', 'The state path that works with IMPORTS (NONE: none of the candidates)', 'select ''' || $state_form || '''', '!NONE');

-- 3 and 4: state:modified, with the state imported at ./imports/state -------------------------------------
set st = $state_form;
call spike_lab.evidence.run_dbt_imp($run_id, 'S6.B30', 'prod target: state:modified (only the changed model expected)',
  'list --select state:modified --resource-type model --state ./imports/state --target prod_erp --target-path target/s6state --log-path logs/s6state', $st, true);
call spike_lab.evidence.run_dbt_imp($run_id, 'S6.B40', 'ci target: state:modified (do all models differ in relation? ci_erp against erp)',
  'list --select state:modified --resource-type model --state ./imports/state --target ci --target-path target/s6ci --log-path logs/s6ci', $st, true);
call spike_lab.evidence.run_dbt_imp($run_id, 'S6.B41', 'ci target: state:modified.body (the real change only)',
  'list --select state:modified.body --resource-type model --state ./imports/state --target ci --target-path target/s6ci --log-path logs/s6ci', $st, true);
call spike_lab.evidence.run_dbt_imp($run_id, 'S6.B42', 'ci target: state:modified.body+ (the change and what depends on it)',
  'list --select state:modified.body+ --resource-type model --state ./imports/state --target ci --target-path target/s6ci --log-path logs/s6ci', $st, true);

-- 5: the CI slim build with --defer -----------------------------------------------------------------------------
drop schema if exists silver.ci_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');
set ci_freeze = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources --args "{unit: erp, watermark: '
  || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" --target ci --target-path target/ci --log-path logs/ci''');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.50', 'ci: freeze into ci_erp', $ci_freeze, 'true');

-- Negative control first: the changed table alone, WITHOUT --defer: its parent view is not in ci_erp
set b_nodefer = (select 'execute dbt project silver.ops.silver_layer args = ''build --select erp_accounts --target ci --target-path target/ci --log-path logs/ci''');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.51', 'ci: build erp_accounts WITHOUT --defer fails (the parent view is not in ci_erp)', $b_nodefer, 'ERROR:%');
set b_defer = (select 'execute dbt project silver.ops.silver_layer args = ''build --select erp_accounts --defer --state ./imports/state --target ci --target-path target/ci --log-path logs/ci'' imports = (''' || $st || ''' as ''state'')');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.52', 'ci: build erp_accounts WITH --defer succeeds (the parent is read from the published schema)', $b_defer, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.53', 'ci: only the selected table was built in ci_erp; the deferred parent was not built there',
  $$select listagg(table_name, ', ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'CI_ERP' and table_name not like 'RAW__%' and table_name <> '_FREEZE'$$, 'ERP_ACCOUNTS');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.54', 'ci: the CI table equals the published one (same rows)',
  $$select iff((select count(*) from silver.ci_erp.erp_accounts) = (select count(*) from silver.erp.erp_accounts), 'SAME_COUNT', 'DIFFERENT')$$, 'SAME_COUNT');

-- The CI pattern: build what the change touches and what depends on it
set b_slim = (select 'execute dbt project silver.ops.silver_layer args = ''build --select state:modified.body+ --defer --state ./imports/state --target ci --target-path target/ci --log-path logs/ci'' imports = (''' || $st || ''' as ''state'')');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.55', 'ci: slim build, state:modified.body+ with --defer', $b_slim, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.56', 'ci: the changed view and its dependent table are in ci_erp, the unchanged orders models are not',
  $$select listagg(table_name, ', ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'CI_ERP' and table_name not like 'RAW__%' and table_name <> '_FREEZE'$$,
  'ERP_ACCOUNTS, STG_ERP__ACCOUNTS');

-- The published schema was not touched by any CI step
set after_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');
call spike_lab.evidence.probe($run_id, 'S6', 'S6b.57', 'The published ERP schema was not touched by the CI run',
  'select iff(''' || $base_pub || ''' = ''' || $after_pub || ''', ''UNTOUCHED'', ''CHANGED'')', 'UNTOUCHED');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
