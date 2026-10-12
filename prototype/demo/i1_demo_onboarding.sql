-- =============================================================================
-- Prototype / Increment 1 / Demo: stewards onboard Silver units themselves
--
-- What it shows (LLD 01, 7.1.1 and 7.3; verification item V-IA-9):
--   1. A steward, as SILVER_OPERATOR, onboards four units (ERP, CRM, HR (sensitive),
--      Core) without CREATE ROLE and without an administrator.
--   2. Each unit gets its own service role, owning its managed-access schema; Core
--      reads ERP and CRM through their reader roles; nothing reads HR by default.
--   3. The platform grants raw access; a unit reads only its own source.
--   4. Consumers: ANALYST_ALL sees every non-sensitive unit, ANALYST_HR sees HR only.
--   5. Guard rails: bad names, unknown units, missing upstreams and dependents are
--      refused; onboarding is safe to rerun; offboarding retires a unit completely
--      and it can be onboarded again.
--
-- Case ids INC1.nn (INC1.00 to INC1.42). Export the final query to evidence/INC1_<yyyymmdd>.csv.
-- Rerunnable: Part 0 resets the four demo units.
-- Trial shortcut T1: one user acts as every role, including unit roles (Part 5).
-- Run as: the switching user. Requires: i1_10, i1_20, i1_30, i1_40.
-- =============================================================================

use secondary roles none;
set me = (select current_user());
set run_id = (select uuid_string());

-- Part 0: reset the demo units (configuration first, so nothing has dependents) -----------
use role silver_steward;
use warehouse lld_wh;   -- after USE ROLE: the role in force must have USAGE
delete from analytics_ops.control.unit_dependencies
  where unit in ('silver.erp', 'silver.crm', 'silver.hr', 'silver.core');
delete from analytics_ops.control.units
  where unit in ('raw.erp', 'raw.crm', 'raw.hr', 'silver.erp', 'silver.crm', 'silver.hr', 'silver.core');

use role silver_operator;
call silver.ops.offboard_unit('silver.core');
call silver.ops.offboard_unit('silver.erp');
call silver.ops.offboard_unit('silver.crm');
call silver.ops.offboard_unit('silver.hr');

-- Part 1: configuration, as reviewed in the ops repository (SLD 12.3) ---------------------
use role silver_steward;
insert into analytics_ops.control.units (unit, tier, owner, sensitive) values
  ('raw.erp',     'RAW',  'platform', false),
  ('raw.crm',     'RAW',  'platform', false),
  ('raw.hr',      'RAW',  'platform', true),
  ('silver.erp',  'T0',   'stewards', false),
  ('silver.crm',  'T0',   'stewards', false),
  ('silver.hr',   'T0',   'stewards', true),
  ('silver.core', 'T0.5', 'stewards', false);
insert into analytics_ops.control.unit_dependencies (unit, upstream_unit, max_age_hours) values
  ('silver.erp',  'raw.erp',    24),
  ('silver.crm',  'raw.crm',    24),
  ('silver.hr',   'raw.hr',     24),
  ('silver.core', 'silver.erp', 24),
  ('silver.core', 'silver.crm', 24);

-- Part 2: onboarding by the operator --------------------------------------------------------
use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.00', 'Core is refused before its upstreams are onboarded',
  $$call silver.ops.onboard_unit('silver.core')$$, 'REFUSED:upstream_not_onboarded');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.01', 'Operator onboards ERP',
  $$call silver.ops.onboard_unit('silver.erp')$$, 'ONBOARDED:SVC_SILVER_ERP (schema created)');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.02', 'Operator onboards CRM',
  $$call silver.ops.onboard_unit('silver.crm')$$, 'ONBOARDED:SVC_SILVER_CRM (schema created)');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.03', 'Operator onboards HR (sensitive)',
  $$call silver.ops.onboard_unit('silver.hr')$$, 'ONBOARDED:SVC_SILVER_HR (schema created)');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.04', 'Operator onboards Core after its upstreams',
  $$call silver.ops.onboard_unit('silver.core')$$, 'ONBOARDED:SVC_SILVER_CORE (schema created)');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.05', 'A malformed unit name is refused (no SQL injection)',
  $$call silver.ops.onboard_unit('silver.erp; drop role silver_operator')$$, 'REFUSED:invalid_unit_name');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.06', 'A unit missing from configuration is refused',
  $$call silver.ops.onboard_unit('silver.nounit')$$, 'REFUSED:not_in_units');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.07', 'The operator cannot create a role directly',
  $$create role inc1_should_not_exist$$, 'ERROR:%');
use role silver_steward;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.08', 'The steward owner role cannot create a role directly',
  $$create role inc1_should_not_exist$$, 'ERROR:%');

-- Part 3: the platform grants raw access (onboarding runbook, platform step) -------------
use role platform_ingest;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.09', 'Platform grants raw.reader_erp to the ERP unit role',
  $$grant database role raw.reader_erp to role svc_silver_erp$$, '!ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.10', 'Platform grants raw.reader_crm to the CRM unit role',
  $$grant database role raw.reader_crm to role svc_silver_crm$$, '!ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.11', 'Platform grants raw.reader_hr to the HR unit role',
  $$grant database role raw.reader_hr to role svc_silver_hr$$, '!ERROR:%');

-- Part 4: consumer access ---------------------------------------------------------------
use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.12', 'Operator grants the aggregate reader to ANALYST_ALL',
  $$call silver.ops.grant_unit_reader('silver', 'analyst_all')$$, 'GRANTED:silver.reader to ANALYST_ALL');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.13', 'Operator grants the HR reader to ANALYST_HR',
  $$call silver.ops.grant_unit_reader('silver.hr', 'analyst_hr')$$, 'GRANTED:silver.reader_hr to ANALYST_HR');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.14', 'A reader role cannot be granted to a service role this way',
  $$call silver.ops.grant_unit_reader('silver.hr', 'svc_silver_core')$$, 'REFUSED:invalid_role');

-- Part 5: what was created (inspection as SYSADMIN, which inherits every unit role) ------
use role sysadmin;
show roles like 'SVC_SILVER_%';
set obs = (select listagg("name" || ':' || "owner", ',') within group (order by "name")
           from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.15', 'One service role per unit, owned by the provisioner',
  'show roles like ''SVC_SILVER_%''',
  'SVC_SILVER_CORE:SILVER_PROVISIONER,SVC_SILVER_CRM:SILVER_PROVISIONER,SVC_SILVER_ERP:SILVER_PROVISIONER,SVC_SILVER_HR:SILVER_PROVISIONER', $obs);

show schemas in database silver;
set obs = (select listagg("name" || ':' || "owner" || ':' || "options", ',') within group (order by "name")
           from table(result_scan(last_query_id())) where "name" in ('ERP', 'CRM', 'HR', 'CORE'));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.16', 'Each published schema is owned by its unit role and managed access',
  'show schemas in database silver',
  'CORE:SVC_SILVER_CORE:MANAGED ACCESS,CRM:SVC_SILVER_CRM:MANAGED ACCESS,ERP:SVC_SILVER_ERP:MANAGED ACCESS,HR:SVC_SILVER_HR:MANAGED ACCESS', $obs);

-- In a block, so a missing role is recorded as a FAIL instead of stopping the demo
declare v varchar; begin
  show grants to role svc_silver_core;
  select listagg("name", ',') within group (order by "name") into :v
    from table(result_scan(last_query_id())) where "granted_on" in ('ROLE', 'DATABASE_ROLE');
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.17', 'Core holds the ERP and CRM reader roles, the unit base and the task runner',
  'show grants to role svc_silver_core', '%READER_CRM%READER_ERP%SILVER_UNIT_BASE%TASK_RUNNER%', $obs);
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.18', 'Core does not hold the HR reader role (not a declared upstream)',
  'show grants to role svc_silver_core', '!%READER_HR%', $obs);

declare v varchar; begin
  show grants to role svc_silver_erp;
  select listagg("name", ',') within group (order by "name") into :v
    from table(result_scan(last_query_id())) where "granted_on" in ('ROLE', 'DATABASE_ROLE');
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.19', 'ERP holds its raw reader role (from the platform), the unit base and the task runner',
  'show grants to role svc_silver_erp', '%RAW.READER_ERP%SILVER_UNIT_BASE%TASK_RUNNER%', $obs);

use role silver_provisioner;
show grants to database role silver.reader;
set obs = (select listagg("name", ',') within group (order by "name")
           from table(result_scan(last_query_id())) where "granted_on" = 'DATABASE_ROLE');
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.20', 'The aggregate reader holds the non-sensitive unit readers',
  'show grants to database role silver.reader', '%READER_CORE%READER_CRM%READER_ERP%', $obs);
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.21', 'The aggregate reader does not hold the sensitive HR reader',
  'show grants to database role silver.reader', '!%READER_HR%', $obs);

-- Part 6: privileges in use, as the unit roles (trial shortcut T1) -----------------------
use role silver_provisioner;
grant role svc_silver_erp  to user identifier($me);
grant role svc_silver_crm  to user identifier($me);
grant role svc_silver_hr   to user identifier($me);
grant role svc_silver_core to user identifier($me);

-- Stand-in for the first publication (Increment 2): the unit role, as schema owner, grants
-- USAGE on its schema to its reader role. Onboarding hands the schema over with no grants.
use role svc_silver_erp;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.42', 'The unit role (schema owner) grants USAGE to its reader role, as publication will',
  $$grant usage on schema silver.erp to database role silver.reader_erp$$, '!ERROR:%');
use role svc_silver_crm;
grant usage on schema silver.crm to database role silver.reader_crm;
use role svc_silver_hr;
grant usage on schema silver.hr to database role silver.reader_hr;
use role svc_silver_core;
grant usage on schema silver.core to database role silver.reader_core;

use role svc_silver_erp;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.22', 'ERP role clones its own build schema (managed access), as publication will',
  $$create or replace schema silver.erp__build clone silver.erp with managed access$$, '!ERROR:%');
drop schema if exists silver.erp__build;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.23', 'ERP role reads its own raw source',
  $$select count(*) from raw.erp.accounts$$, '1');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.24', 'ERP role cannot read another source',
  $$select count(*) from raw.crm.contacts$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.25', 'ERP role cannot clone (or touch) the CRM unit',
  $$create or replace schema silver.crm__build clone silver.crm with managed access$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.26', 'ERP role cannot write the run-control log directly',
  $$insert into analytics_ops.control.publish_log (unit, event_type) values ('silver.erp', 'PUBLISHED')$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.27', 'Residual risk (LLD 01, 9): a unit role can create any schema in silver',
  $$create schema if not exists silver.inc1_stray$$, null);
drop schema if exists silver.inc1_stray;

use role svc_silver_core;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.28', 'Core role has no raw access',
  $$select count(*) from raw.erp.accounts$$, 'ERROR:%');

-- Part 7: what consumers see -------------------------------------------------------------
use role analyst_all;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.29', 'ANALYST_ALL sees the non-sensitive unit schemas only',
  $$select listagg(schema_name, ',') within group (order by schema_name) from silver.information_schema.schemata where schema_name not in ('INFORMATION_SCHEMA', 'PUBLIC')$$,
  'CORE,CRM,ERP');
use role analyst_hr;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.30', 'ANALYST_HR sees the HR unit schema only',
  $$select listagg(schema_name, ',') within group (order by schema_name) from silver.information_schema.schemata where schema_name not in ('INFORMATION_SCHEMA', 'PUBLIC')$$,
  'HR');

-- Part 8: run control records it ----------------------------------------------------------
use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.31', 'An ONBOARDED event for each unit',
  $$select count(distinct unit) from analytics_ops.control.publish_log where event_type = 'ONBOARDED' and unit in ('silver.erp', 'silver.crm', 'silver.hr', 'silver.core')$$, '4');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.32', 'A lease row for each unit',
  $$select count(*) from analytics_ops.control.unit_lease where unit in ('silver.erp', 'silver.crm', 'silver.hr', 'silver.core')$$, '4');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.33', 'Access grants are logged',
  $$select count(*) from analytics_ops.control.publish_log where event_type = 'ACCESS_GRANTED' and event_ts > dateadd(hour, -1, sysdate())$$, '!0');

-- Part 9: rerun and retirement --------------------------------------------------------------
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.34', 'Onboarding again re-applies grants and leaves the schema alone',
  $$call silver.ops.onboard_unit('silver.erp')$$, 'ONBOARDED:SVC_SILVER_ERP (schema existing)');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.35', 'ERP cannot be offboarded while Core depends on it',
  $$call silver.ops.offboard_unit('silver.erp')$$, 'REFUSED:has_dependents:silver.core');
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.36', 'HR is offboarded',
  $$call silver.ops.offboard_unit('silver.hr')$$, 'OFFBOARDED:SVC_SILVER_HR');

use role sysadmin;
show schemas in database silver;
set obs = (select listagg("name" || ':' || "owner" || ':' || "options", ',') within group (order by "name")
           from table(result_scan(last_query_id())) where "name" in ('ERP', 'CRM', 'HR', 'CORE'));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.37', 'After a rerun and an offboarding: ERP unchanged, HR gone',
  'show schemas in database silver',
  'CORE:SVC_SILVER_CORE:MANAGED ACCESS,CRM:SVC_SILVER_CRM:MANAGED ACCESS,ERP:SVC_SILVER_ERP:MANAGED ACCESS', $obs);
show roles like 'SVC_SILVER_HR';
set obs = (select count(*) from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.38', 'The HR service role is gone', 'show roles like ''SVC_SILVER_HR''', '0', $obs);
show database roles in database silver;
set obs = (select count(*) from table(result_scan(last_query_id())) where "name" = 'READER_HR');
call lld_lab.evidence.record($run_id, 'INC1', 'INC1.39', 'The HR reader role is gone', 'show database roles in database silver', '0', $obs);

use role analyst_hr;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.40', 'ANALYST_HR has lost access with the unit',
  $$select listagg(schema_name, ',') within group (order by schema_name) from silver.information_schema.schemata where schema_name not in ('INFORMATION_SCHEMA', 'PUBLIC')$$,
  '!HR');

use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC1', 'INC1.41', 'HR can be onboarded again',
  $$call silver.ops.onboard_unit('silver.hr')$$, 'ONBOARDED:SVC_SILVER_HR (schema created)');
call silver.ops.grant_unit_reader('silver.hr', 'analyst_hr');
use role platform_ingest;
grant database role raw.reader_hr to role svc_silver_hr;

-- Result -----------------------------------------------------------------------------------------
use role sysadmin;
select case_id, outcome, description, observed, role_name, observed_at
from lld_lab.evidence.observation where run_id = $run_id order by case_id;
