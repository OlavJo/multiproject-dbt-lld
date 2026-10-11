-- =============================================================================
-- Prototype / Increment 1 / Step 10: foundation roles and databases
--
-- Implements LLD 01 (Identity and Access) Sections 5 and 7.1.1, decisions IA-1,
-- IA-3, IA-4 (proposed). Creates the roles that exist before any unit does:
--
--   owner roles      PLATFORM_INGEST (raw), SILVER_STEWARD (silver, analytics_ops)
--   utility roles    SILVER_PROVISIONER (creates and retires unit roles; CREATE ROLE)
--   access roles     SILVER_UNIT_BASE (privileges common to every unit role),
--                    TASK_RUNNER (EXECUTE TASK); both OWNED by the provisioner,
--                    which is what lets it grant them to new unit roles
--   functional roles SILVER_OPERATOR (stewards' daily role), ANALYST_ALL and
--                    ANALYST_HR (prototype consumers)
--
-- and the databases RAW, SILVER, ANALYTICS_OPS, owned by their owner roles.
-- Unit service roles are NOT created here: onboard_unit creates them (step 40).
--
-- Trial shortcuts (prototype/README.md): the running user is granted every role
-- here (T1); SPIKE_WH serves every role (T3).
--
-- Run as: USERADMIN, SECURITYADMIN, ACCOUNTADMIN, SYSADMIN (switches itself).
-- Requires: 00_teardown_spikes.sql. Idempotent.
-- =============================================================================

use secondary roles none;
set me = (select current_user());

-- Roles ---------------------------------------------------------------------------
use role useradmin;
create role if not exists platform_ingest    comment = 'Owner: raw landing (platform team)';
create role if not exists silver_steward     comment = 'Owner: silver and analytics_ops databases (Silver stewards; used by deployment)';
create role if not exists silver_provisioner comment = 'Utility: owns onboard_unit/offboard_unit and the unit roles they create. Never granted to a person in production';
create role if not exists silver_unit_base   comment = 'Access role: privileges every Silver unit service role needs';
create role if not exists task_runner        comment = 'Access role: EXECUTE TASK on the account';
create role if not exists silver_operator    comment = 'Functional: Silver stewards operating the platform (onboarding, access, re-runs)';
create role if not exists analyst_all        comment = 'Prototype consumer: reads all non-sensitive Silver units';
create role if not exists analyst_hr         comment = 'Prototype consumer: reads the sensitive HR unit only';

use role securityadmin;
-- The provisioner grants these two to every new unit role, so it must own them.
-- SECURITYADMIN (MANAGE GRANTS) transfers them, so a rerun also succeeds.
grant ownership on role silver_unit_base to role silver_provisioner;
grant ownership on role task_runner      to role silver_provisioner;

grant role platform_ingest    to role sysadmin;
grant role silver_steward     to role sysadmin;
grant role silver_provisioner to role sysadmin;
grant role silver_operator    to role sysadmin;
grant role analyst_all        to role sysadmin;
grant role analyst_hr         to role sysadmin;

-- Account privileges (Section 6.5)
grant create role on account to role silver_provisioner;

-- Trial shortcut T1: the running user holds every role
grant role platform_ingest    to user identifier($me);
grant role silver_steward     to user identifier($me);
grant role silver_provisioner to user identifier($me);
grant role silver_operator    to user identifier($me);
grant role analyst_all        to user identifier($me);
grant role analyst_hr         to user identifier($me);

use role accountadmin;
grant execute task on account to role task_runner;

-- The provisioner makes its access roles visible to administrators
use role silver_provisioner;
grant role silver_unit_base to role sysadmin;
grant role task_runner      to role sysadmin;

-- Databases -------------------------------------------------------------------------
use role sysadmin;
create database if not exists raw           comment = 'Prototype: simulated Bronze landing (platform-owned)';
create database if not exists silver        comment = 'Prototype: Silver Layer';
create database if not exists analytics_ops comment = 'Prototype: run control';
grant ownership on database raw           to role platform_ingest copy current grants;
grant ownership on database silver        to role silver_steward  copy current grants;
grant ownership on database analytics_ops to role silver_steward  copy current grants;

-- Warehouse (trial shortcut T3; OC-1 is open) ---------------------------------------
grant usage on warehouse spike_wh to role platform_ingest;
grant usage on warehouse spike_wh to role silver_steward;
grant usage on warehouse spike_wh to role silver_provisioner;
grant usage on warehouse spike_wh to role silver_unit_base;
grant usage on warehouse spike_wh to role silver_operator;
grant usage on warehouse spike_wh to role analyst_all;
grant usage on warehouse spike_wh to role analyst_hr;

-- Evidence store: every prototype role may record observations ------------------------
-- RECORD is the companion of PROBE for observations read from SHOW output:
--   show ...; set obs = (select ... from table(result_scan(last_query_id())));
--   call spike_lab.evidence.record($run_id, 'INC1', 'INC1.10', 'what', 'show ...', '<ILIKE pattern>', $obs);
create or replace procedure spike_lab.evidence.record(
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
  insert into spike_lab.evidence.observation
    select :run_id, :spike, :case_id, :description, :sql_text, :expected, :v_obs, :v_outcome,
           current_role(), current_secondary_roles(), sysdate(), current_version(), null;
  return v_outcome || ' | ' || case_id || ' | ' || v_obs;
end;
$$;

declare
  c_roles cursor for
    select value::varchar as r from table(flatten(input => parse_json(
      '["PLATFORM_INGEST","SILVER_STEWARD","SILVER_PROVISIONER","SILVER_UNIT_BASE","SILVER_OPERATOR","ANALYST_ALL","ANALYST_HR"]')));
begin
  for rec in c_roles do
    execute immediate 'grant usage on database spike_lab to role ' || rec.r;
    execute immediate 'grant usage on schema spike_lab.evidence to role ' || rec.r;
    execute immediate 'grant select, insert on table spike_lab.evidence.observation to role ' || rec.r;
    execute immediate 'grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role ' || rec.r;
    execute immediate 'grant usage on procedure spike_lab.evidence.record(varchar, varchar, varchar, varchar, varchar, varchar, varchar) to role ' || rec.r;
  end for;
  return 'evidence grants done';
end;

-- Check -------------------------------------------------------------------------------
show roles like 'SILVER_%';
select "name", "owner", "comment" from table(result_scan(last_query_id())) order by "name";
