-- =============================================================================
-- Spike S8: concurrent units on one live-version project object
-- See README.md in this folder.
--
-- SLD 3.1, 10.3: all Silver units share one project object (silver.ops.silver_layer)
-- and run concurrently, each with its own --target-path and --log-path. Questions:
--   A  do two units really publish at the same time on one object, under one
--      orchestrating role (SYSADMIN, which inherits both unit roles), and does each
--      end up correct and independent?
--   B  how many EXECUTE DBT PROJECT statements were in progress together?
--   C  what do SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET and SYSTEM$LOCATE_DBT_ARTIFACTS
--      return with two units on one object (which unit's state)?
--   D  is partial-parsing state independent per target path (a run of one unit in
--      between does not invalidate the other's), and does changing --vars invalidate it?
--   E  what happens when two concurrent executions share one target path?
-- (F, a deployment during running units, is a separate script.)
--
-- Requires setup/08 (with the attribution update) and the state left by the P3 and S3 scripts.
-- Run as: SYSADMIN (helpers, the orchestrating role), PLATFORM_INGEST, ACCOUNTADMIN
-- (query history), SILVER_STEWARD (final query). The script switches roles itself.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Helpers (SYSADMIN owns SPIKE_LAB.EVIDENCE) ------------------------------------------------
use role sysadmin;

-- Records one EXECUTE DBT PROJECT call with the flags this spike needs
create or replace procedure spike_lab.evidence.run_dbt2(
    p_run_id varchar, p_case varchar, p_desc varchar, p_args varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_sql    varchar;
  v_ok     boolean;
  v_exc    varchar;
  v_out    varchar;
  v_raised boolean default false;
  v_err    varchar;
  v_qid    varchar;
  v_t0     timestamp_ntz default sysdate();
begin
  v_sql := 'execute dbt project silver.ops.silver_layer args = ''' || replace(p_args, '''', '''''') || '''';
  begin
    execute immediate :v_sql;
    select last_query_id() into :v_qid;
    select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
      from table(result_scan(:v_qid));
  exception
    when other then
      v_raised := true;
      v_err := sqlerrm;
  end;
  insert into spike_lab.evidence.observation
    select :p_run_id, 'S8', :p_case, :p_desc, :v_sql, null,
           iff(:v_raised, 'RAISED: ' || left(:v_err, 600), 'success=' || nvl(:v_ok::varchar, 'null')),
           iff(:v_raised, 'FAIL', iff(coalesce(:v_ok, false), 'INFO', 'FAIL')),
           current_role(), current_secondary_roles(), sysdate(), current_version(),
           object_construct('query_id', :v_qid, 'raised', :v_raised, 'error', left(:v_err, 1500),
             'started_at', :v_t0, 'ended_at', sysdate(),
             'partial_parse_unable', contains(:v_out, 'Unable to do partial parsing'),
             'partial_parse_lines', array_to_string(regexp_substr_all(:v_out, '[^\n]*artial pars[^\n]*'), ' | '),
             'writeback_lines', array_to_string(regexp_substr_all(:v_out, '[^\n]*[Ww]riteback[^\n]*'), ' | '),
             'stdout_chars', length(:v_out));
  return iff(:v_raised, 'RAISED', 'success=' || nvl(:v_ok::varchar, 'null'));
end;
$$;

-- Two units published at the same moment by one caller
create or replace procedure spike_lab.evidence.s8_run_pair()
  returns varchar
  language sql
  execute as caller
as
$$
begin
  async (call silver.ops.publish_unit('silver.erp'));
  async (call silver.ops.publish_unit('silver.crm'));
  await all;
  return 'done';
end;
$$;

-- Two executions that share one target path, at the same moment
create or replace procedure spike_lab.evidence.s8_run_shared_path(p_run_id varchar)
  returns varchar
  language sql
  execute as caller
as
$$
begin
  async (call spike_lab.evidence.run_dbt2(:p_run_id, 'S8.E1', 'E: ERP parse, shared target path, concurrent',
    'parse --target prod_erp --vars "{publish_unit: erp}" --target-path target/shared --log-path logs/shared'));
  async (call spike_lab.evidence.run_dbt2(:p_run_id, 'S8.E2', 'E: CRM parse, shared target path, concurrent',
    'parse --target prod_crm --vars "{publish_unit: crm}" --target-path target/shared --log-path logs/shared'));
  await all;
  return 'done';
end;
$$;

-- =============================================================================
-- Part A: two units publish concurrently on one project object
-- =============================================================================
use role platform_ingest;
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);

use role sysadmin;
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A1',
  'Both units published at the same moment by one orchestrating role (SYSADMIN)',
  $$call spike_lab.evidence.s8_run_pair()$$, 'done');
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A2', 'Both units logged PUBLISHED in the last 15 minutes',
  $$select count(distinct unit) from analytics_ops.control.publish_log where event_type = 'PUBLISHED' and unit in ('silver.erp', 'silver.crm') and event_ts > dateadd(minute, -15, sysdate())$$, '2');
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A3', 'Their runs overlapped in time (STARTED of each before PUBLISHED of the other)',
  $$with e as (select unit, max(iff(event_type = 'STARTED', event_ts, null)) as s, max(iff(event_type = 'PUBLISHED', event_ts, null)) as p from analytics_ops.control.publish_log where unit in ('silver.erp', 'silver.crm') and event_ts > dateadd(minute, -15, sysdate()) group by unit)
    select iff((select s from e where unit = 'silver.erp') < (select p from e where unit = 'silver.crm') and (select s from e where unit = 'silver.crm') < (select p from e where unit = 'silver.erp'), 'OVERLAP', 'SERIAL')$$,
  'OVERLAP');
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A4', 'Timeline: STARTED and PUBLISHED times of the two runs',
  $$select listagg(unit || ' ' || event_type || ' ' || to_varchar(event_ts, 'HH24:MI:SS.FF1'), ' | ') within group (order by event_ts) from analytics_ops.control.publish_log where unit in ('silver.erp', 'silver.crm') and event_type in ('STARTED', 'PUBLISHED') and event_ts > dateadd(minute, -15, sysdate())$$,
  null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A5', 'Leases of both units are free',
  $$select count(*) from analytics_ops.control.unit_lease where unit in ('silver.erp', 'silver.crm') and run_id is not null$$, '0');
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A6', 'Each unit holds its own data: ERP current orders and CRM contacts (counts)',
  $$select (select count(*) from silver.erp.erp_orders_current) || ' orders / ' || (select count(*) from silver.crm.crm_contacts) || ' contacts'$$, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A7', 'Both PUBLISHED events carry their own canonical state query id (distinct)',
  $$select count(distinct detail:state_query_id::varchar) from analytics_ops.control.publish_log where event_type = 'PUBLISHED' and unit in ('silver.erp', 'silver.crm') and event_ts > dateadd(minute, -15, sysdate())$$, '2');
call spike_lab.evidence.probe($run_id, 'S8', 'S8.A8', 'Canonical compile ok for both',
  $$select count_if(detail:canonical_ok::boolean) from analytics_ops.control.publish_log where event_type = 'PUBLISHED' and unit in ('silver.erp', 'silver.crm') and event_ts > dateadd(minute, -15, sysdate())$$, '2');

-- =============================================================================
-- Part B: concurrency in query history (ACCOUNTADMIN sees nested statements)
-- =============================================================================
use role accountadmin;
insert into spike_lab.evidence.observation
  with q as (
    select query_id, start_time, end_time, total_elapsed_time
    from table(spike_lab.information_schema.query_history(
           end_time_range_start => dateadd(minute, -20, current_timestamp()), result_limit => 10000))
    where query_text ilike 'execute dbt project%'
  ),
  o as (
    select a.query_id, count(*) as overlapping
    from q a join q b on b.start_time < a.end_time and b.end_time > a.start_time
    group by a.query_id
  )
  select $run_id, 'S8', 'S8.B1', 'EXECUTE DBT PROJECT statements in the last 20 minutes and the most in progress together',
         'information_schema.query_history', null,
         'statements=' || (select count(*) from q) || '; max_concurrent=' || (select max(overlapping) from o),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null;

-- =============================================================================
-- Part C: which state does the object report with two units on it?
-- =============================================================================
use role sysadmin;
call spike_lab.evidence.probe($run_id, 'S8', 'S8.C1', 'SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET on the shared object',
  $$select system$dbt_get_last_successful_run_target('silver.ops.silver_layer')$$, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8.C2', 'LOCATE_DBT_ARTIFACTS for the ERP canonical query id',
  $$select system$locate_dbt_artifacts((select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1))$$, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8.C3', 'LOCATE_DBT_ARTIFACTS for the CRM canonical query id',
  $$select system$locate_dbt_artifacts((select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.crm' and event_type = 'PUBLISHED' order by event_ts desc limit 1))$$, null);

-- =============================================================================
-- Part D: partial parsing per target path
-- Sequence: ERP, ERP again, CRM, ERP again (a CRM run in between), ERP with other vars, ERP again.
-- =============================================================================
call spike_lab.evidence.run_dbt2($run_id, 'S8.D1', 'D: ERP parse (state from earlier runs may exist)',
  'parse --target prod_erp --vars "{publish_unit: erp}" --target-path target/erp --log-path logs/erp');
call spike_lab.evidence.run_dbt2($run_id, 'S8.D2', 'D: ERP parse again, same arguments: partial parsing expected',
  'parse --target prod_erp --vars "{publish_unit: erp}" --target-path target/erp --log-path logs/erp');
call spike_lab.evidence.run_dbt2($run_id, 'S8.D3', 'D: CRM parse (a different unit and target path)',
  'parse --target prod_crm --vars "{publish_unit: crm}" --target-path target/crm --log-path logs/crm');
call spike_lab.evidence.run_dbt2($run_id, 'S8.D4', 'D: ERP parse again after the CRM run: is its state still valid?',
  'parse --target prod_erp --vars "{publish_unit: erp}" --target-path target/erp --log-path logs/erp');
call spike_lab.evidence.run_dbt2($run_id, 'S8.D5', 'D: ERP parse with different --vars: full re-parse expected (SLD 3.2)',
  'parse --target prod_erp --vars "{publish_unit: erp, inject_failure: none}" --target-path target/erp --log-path logs/erp');
call spike_lab.evidence.run_dbt2($run_id, 'S8.D6', 'D: ERP parse with the original vars again',
  'parse --target prod_erp --vars "{publish_unit: erp}" --target-path target/erp --log-path logs/erp');

-- =============================================================================
-- Part E: two concurrent executions on one target path
-- =============================================================================
call spike_lab.evidence.probe($run_id, 'S8', 'S8.E0', 'Two concurrent parses with the SAME target path (E1, E2 record their own outcomes)',
  $$call spike_lab.evidence.s8_run_shared_path('$$ || $run_id || $$')$$, 'done');

-- Evidence ----------------------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;

-- Part D and E detail (the flags are in DETAIL)
select case_id, description, observed,
       detail:partial_parse_unable::varchar as unable, detail:partial_parse_lines::varchar as partial_lines,
       detail:writeback_lines::varchar as writeback_lines, detail:started_at::varchar as started_at, detail:ended_at::varchar as ended_at
from spike_lab.evidence.observation where run_id = $run_id and case_id like 'S8.D%' or run_id = $run_id and case_id like 'S8.E%'
order by observed_at, case_id;
