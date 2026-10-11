-- =============================================================================
-- Phase 0 / Step 01: Account checks
-- Records the facts about this account that every later result depends on.
-- Run as: ACCOUNTADMIN (read-only checks, plus two Enterprise feature probes
-- that create objects only in SPIKE_LAB.EVIDENCE).
-- =============================================================================

use role accountadmin;
use secondary roles none;
use warehouse spike_wh;

set run_id = (select uuid_string());

-- Identity and release ---------------------------------------------------------
call spike_lab.evidence.probe($run_id, 'P0', 'P0.01', 'Organisation and account',
  $$select current_organization_name() || '.' || current_account_name()$$, null);

call spike_lab.evidence.probe($run_id, 'P0', 'P0.02', 'Cloud region',
  $$select current_region()$$, null);

call spike_lab.evidence.probe($run_id, 'P0', 'P0.03', 'Snowflake release',
  $$select current_version()$$, null);

-- Live-version dbt project objects (SLD 3.2) -------------------------------------
-- Recorded inline, not through PROBE or RESULT_SCAN. Reading this function's
-- result back through RESULT_SCAN fails with "String 'ENABLED' is too long and
-- would be truncated" (spike log, 2026-10-05). P0.04a records the declared type
-- of the function's result column as evidence of the cause.
select system$behavior_change_bundle_status('2026_06');
describe result last_query_id();
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.04a',
         'Declared type of SYSTEM$BEHAVIOR_CHANGE_BUNDLE_STATUS result column (diagnostic)',
         'describe result last_query_id()', null,
         "type", 'INFO',
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct(*)
  from table(result_scan(last_query_id()));

insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.04',
         '2026_06 behaviour change bundle enabled (live-version dbt project objects)',
         'select system$behavior_change_bundle_status(''2026_06'')', 'ENABLED',
         s, iff(s = 'ENABLED', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select system$behavior_change_bundle_status('2026_06')::varchar as s);

-- dbt runtimes (Overview 2, SLD 3.3) ----------------------------------------------
call spike_lab.evidence.probe($run_id, 'P0', 'P0.05',
  'Supported dbt versions: 1.11.11 available',
  $$select system$supported_dbt_versions()$$, '%1.11.11%');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.06',
  'Supported dbt versions: is any 1.12.x available (affects latest_version_pointer, Overview 8.2)',
  $$select system$supported_dbt_versions()$$, '%1.12.%');

show parameters like 'DEFAULT_DBT_VERSION' in account;
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.07', 'Account default dbt version (used when DBT_VERSION is not pinned)',
         'show parameters like ''DEFAULT_DBT_VERSION'' in account', null,
         "value", 'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

-- Secondary roles default of the spike user (README ground rule 3) ----------------
set me = (select current_user());
describe user identifier($me);
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.08', 'DEFAULT_SECONDARY_ROLES of the spike user (scripts override with USE SECONDARY ROLES NONE)',
         'describe user', null,
         "value", 'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()))
  where "property" = 'DEFAULT_SECONDARY_ROLES';

-- Enterprise Edition features the design relies on --------------------------------
call spike_lab.evidence.probe($run_id, 'P0', 'P0.09',
  'Enterprise: Time Travel retention above 1 day',
  $$alter table spike_lab.evidence.observation set data_retention_time_in_days = 7$$,
  '!ERROR:%');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.10',
  'Enterprise: masking policies (tag-based masking, SLD 6.3)',
  $$create or replace masking policy spike_lab.evidence.mp_edition_check
      as (v varchar) returns varchar -> v$$,
  '!ERROR:%');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.11',
  'Enterprise: ACCESS_HISTORY readable (impact analysis, Overview 8.3)',
  $$select count(*) from snowflake.account_usage.access_history$$,
  '!ERROR:%');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.12',
  'Semantic views available (Overview 4.5, S1)',
  $$show semantic views in account$$,
  '!ERROR:%');

-- Evidence ---------------------------------------------------------------------
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
