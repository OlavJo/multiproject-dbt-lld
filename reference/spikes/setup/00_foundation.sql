-- =============================================================================
-- Phase 0 / Step 00: Foundation
-- Creates the spike warehouse, a cost guard, and the evidence store.
-- Run as: ACCOUNTADMIN (resource monitor) and SYSADMIN (everything else).
-- Idempotent: safe to rerun. Rerunning does NOT delete existing evidence.
-- =============================================================================

use role sysadmin;
use secondary roles none;

-- -----------------------------------------------------------------------------
-- Warehouse used by every spike and every dbt project object in the spikes
-- -----------------------------------------------------------------------------
create warehouse if not exists spike_wh
  warehouse_size      = xsmall
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
  comment             = 'Spikes: multi-project dbt on Snowflake';

-- -----------------------------------------------------------------------------
-- Cost guard. Adjust CREDIT_QUOTA to the trial's remaining credits.
-- Note: resource monitors cover warehouse compute only, not cloud services
-- or serverless features.
-- -----------------------------------------------------------------------------
use role accountadmin;

create or replace resource monitor spike_rm with
  credit_quota    = 60
  frequency       = never
  start_timestamp = immediately
  triggers
    on 50 percent do notify
    on 80 percent do notify
    on 95 percent do suspend
    on 100 percent do suspend_immediate;

alter warehouse spike_wh set resource_monitor = spike_rm;

-- -----------------------------------------------------------------------------
-- Evidence store
-- -----------------------------------------------------------------------------
use role sysadmin;
use warehouse spike_wh;

create database if not exists spike_lab comment = 'Spike scaffolding: evidence, Git, hello project';
create schema   if not exists spike_lab.evidence;

create table if not exists spike_lab.evidence.observation (
  run_id          varchar,        -- one per script execution
  spike           varchar,        -- e.g. 'S1'
  case_id         varchar,        -- e.g. 'S1.08'
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

-- -----------------------------------------------------------------------------
-- PROBE: run one statement as the CALLING role and record what happened.
--
--   call spike_lab.evidence.probe(
--     $run_id, 'S1', 'S1.08', 'what this shows',
--     $$select marker from silver.s1_pub.v$$,
--     'NEW');
--
-- EXPECTED is an ILIKE pattern matched against OBSERVED:
--   'NEW'                  exact (case-insensitive) value
--   'ERROR:%'              any error
--   'ERROR:%not exist%'    a specific error
--   '!ERROR:%'             anything except an error
--   NULL                   informational only (OUTCOME = INFO)
--
-- Caller's rights: the statement runs with the caller's role and session
-- context (current database, schema, secondary roles), so privilege results
-- are those of the calling role.
-- -----------------------------------------------------------------------------
create or replace procedure spike_lab.evidence.probe(
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

  insert into spike_lab.evidence.observation
    select :run_id, :spike, :case_id, :description, :sql_text, :expected,
           :observed, :outcome, current_role(), current_secondary_roles(),
           sysdate(), current_version(), null;

  return outcome || ' | ' || case_id || ' | ' || observed;
end;
$$;

-- -----------------------------------------------------------------------------
-- Self-test of the probe (run as SYSADMIN)
-- -----------------------------------------------------------------------------
set run_id = (select uuid_string());

call spike_lab.evidence.probe($run_id, 'P0', 'P0.00a',
  'Probe self-test: value match',
  $$select 'hello'$$, 'hello');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.00b',
  'Probe self-test: error captured, not raised',
  $$select * from spike_lab.evidence.no_such_table$$, 'ERROR:%');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.00c',
  'Probe self-test: negated pattern',
  $$select 42$$, '!ERROR:%');

select case_id, outcome, observed, role_name, secondary_roles
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Expect three PASS rows, SECONDARY_ROLES = '' (or '[]').
