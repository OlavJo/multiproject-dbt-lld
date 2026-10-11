-- =============================================================================
-- Prototype / Increment 0: lab foundation
--
-- The scaffolding every prototype script relies on, so the prototype can be
-- rebuilt from this repository alone (guardrail 6):
--   warehouse        LLD_WH (trial shortcut T3)
--   resource monitor LLD_RM, the cost guard on LLD_WH
--   evidence store   LLD_LAB.EVIDENCE: the OBSERVATION table and the
--                    caller's-rights procedures PROBE and RECORD (trial
--                    shortcut T6)
--
-- Independent of the spike objects (SPIKE_WH, SPIKE_RM, SPIKE_LAB), which stay
-- on the trial account as the spike record and are not used by the prototype.
-- The table and procedures have the same definitions as the spike set-up
-- (reference/spikes/setup/00), so prototype and spike evidence are directly
-- comparable.
--
-- Run first, before every other prototype script, on the trial account and on
-- a new account alike.
-- Run as: SYSADMIN and ACCOUNTADMIN (switches itself).
-- Idempotent. Rerunning never deletes evidence and never resets the monitor
-- (the procedures are replaced with the same definitions; i1_10 re-grants them).
-- =============================================================================

use role sysadmin;
use secondary roles none;

-- Warehouse -------------------------------------------------------------------------
create warehouse if not exists lld_wh
  warehouse_size      = xsmall
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
  comment             = 'LLD prototype warehouse (trial shortcut T3)';

-- Cost guard ------------------------------------------------------------------------
-- IF NOT EXISTS, not OR REPLACE: replacing a monitor restarts its credit count.
-- Resource monitors cover warehouse compute only, not cloud services or
-- serverless features. Adjust CREDIT_QUOTA with ALTER RESOURCE MONITOR.
use role accountadmin;
create resource monitor if not exists lld_rm with
  credit_quota    = 60
  frequency       = never
  start_timestamp = immediately
  triggers
    on 50 percent do notify
    on 80 percent do notify
    on 95 percent do suspend
    on 100 percent do suspend_immediate;
alter warehouse lld_wh set resource_monitor = lld_rm;

-- Evidence store --------------------------------------------------------------------
use role sysadmin;
use warehouse lld_wh;

create database if not exists lld_lab comment = 'LLD prototype lab: evidence store and Git objects (independent of SPIKE_LAB)';
create schema   if not exists lld_lab.evidence;

create table if not exists lld_lab.evidence.observation (
  run_id          varchar,        -- one per script execution
  spike           varchar,        -- spike or increment, e.g. 'S1', 'INC1'
  case_id         varchar,        -- e.g. 'INC1.08'
  description     varchar,
  sql_text        varchar,        -- exact statement probed
  expected        varchar,        -- ILIKE pattern; '!' prefix negates; NULL = informational
  observed        varchar,        -- first value of first row, or 'ERROR: <message>'
  outcome         varchar,        -- PASS | FAIL | INFO
  role_name       varchar,        -- role that executed the statement
  secondary_roles varchar,        -- secondary roles in force (must be empty)
  observed_at     timestamp_ntz,  -- UTC
  sf_version      varchar,
  detail          variant         -- extra evidence, e.g. dbt STDOUT and query id
);

-- PROBE: run one statement as the CALLING role and record what happened.
--
--   call lld_lab.evidence.probe(
--     $run_id, 'INC1', 'INC1.08', 'what this shows',
--     $$select count(*) from silver.erp.customer$$,
--     '!ERROR:%');
--
-- EXPECTED is an ILIKE pattern matched against OBSERVED:
--   'NEW'                  exact (case-insensitive) value
--   'ERROR:%'              any error
--   'ERROR:%not exist%'    a specific error
--   '!ERROR:%'             anything except an error
--   NULL                   informational only (OUTCOME = INFO)
--
-- Caller's rights: the statement runs with the caller's role and session
-- context, so privilege results are those of the calling role.
create or replace procedure lld_lab.evidence.probe(
    run_id      varchar,
    spike       varchar,
    case_id     varchar,
    description varchar,
    sql_text    varchar,
    expected    varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  observed varchar default '<no rows>';
  outcome  varchar;
begin
  begin
    execute immediate :sql_text;
    let rs resultset := (
      select to_varchar($1) as v
      from table(result_scan(last_query_id()))
      limit 1);
    for r in rs do
      observed := r.v;
    end for;
  exception
    when other then
      observed := 'ERROR: ' || sqlerrm;
  end;

  select nvl(:observed, '<NULL>') into :observed;

  select case
           when :expected is null                         then 'INFO'
           when left(:expected, 1) = '!'
                and not (:observed ilike substr(:expected, 2)) then 'PASS'
           when left(:expected, 1) = '!'                  then 'FAIL'
           when :observed ilike :expected                 then 'PASS'
           else 'FAIL'
         end
    into :outcome;

  insert into lld_lab.evidence.observation
    select :run_id, :spike, :case_id, :description, :sql_text, :expected,
           :observed, :outcome, current_role(), current_secondary_roles(),
           sysdate(), current_version(), null;

  return outcome || ' | ' || case_id || ' | ' || observed;
end;
$$;

-- RECORD: the companion of PROBE for observations read from SHOW output:
--   show ...; set obs = (select ... from table(result_scan(last_query_id())));
--   call lld_lab.evidence.record($run_id, 'INC1', 'INC1.10', 'what', 'show ...', '<ILIKE pattern>', $obs);
create or replace procedure lld_lab.evidence.record(
    run_id varchar, spike varchar, case_id varchar, description varchar,
    sql_text varchar, expected varchar, observed varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_obs     varchar;
  v_outcome varchar;
begin
  v_obs := nvl(observed, '<NULL>');
  select case
           when :expected is null                                         then 'INFO'
           when left(:expected, 1) = '!' and not (:v_obs ilike substr(:expected, 2)) then 'PASS'
           when left(:expected, 1) = '!'                                  then 'FAIL'
           when :v_obs ilike :expected                                    then 'PASS'
           else 'FAIL'
         end into :v_outcome;
  insert into lld_lab.evidence.observation
    select :run_id, :spike, :case_id, :description, :sql_text, :expected, :v_obs, :v_outcome,
           current_role(), current_secondary_roles(), sysdate(), current_version(), null;
  return v_outcome || ' | ' || case_id || ' | ' || v_obs;
end;
$$;

-- Self-test -------------------------------------------------------------------------
set run_id = (select uuid_string());

call lld_lab.evidence.probe($run_id, 'INC0', 'INC0.10', 'Probe self-test: value match',
  $$select 'hello'$$, 'hello');
call lld_lab.evidence.probe($run_id, 'INC0', 'INC0.11', 'Probe self-test: error captured, not raised',
  $$select * from lld_lab.evidence.no_such_table$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC0', 'INC0.12', 'Probe self-test: negated pattern',
  $$select 42$$, '!ERROR:%');
call lld_lab.evidence.record($run_id, 'INC0', 'INC0.13', 'Record self-test: value supplied by the caller',
  'n/a', 'hello', 'hello');

-- As ACCOUNTADMIN: SHOW WAREHOUSES shows the resource monitor only to roles
-- that can see it, so SYSADMIN reads 'null' even when the monitor is set.
use role accountadmin;
show warehouses like 'LLD_WH';
set obs = (select nvl(max("resource_monitor"), '<none>') from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC0', 'INC0.14', 'LLD_WH is guarded by LLD_RM',
  'show warehouses like ''LLD_WH''', 'LLD_RM', $obs);

select case_id, outcome, description, observed, role_name, secondary_roles
from lld_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Expect five PASS rows (INC0.14 recorded by ACCOUNTADMIN) and SECONDARY_ROLES empty.
