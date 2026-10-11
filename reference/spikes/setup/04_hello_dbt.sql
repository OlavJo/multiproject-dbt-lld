-- =============================================================================
-- Phase 0 / Step 04: Hello dbt project
-- Confirms: a dbt project object can be created from Git; it is a live-version
-- object; DBT_VERSION pinning is honoured; the model is built by the profile's
-- role; and whether a 1.12.x runtime can be selected per execution.
-- Run as: SILVER_STEWARD.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse spike_wh;

set run_id = (select uuid_string());

alter git repository spike_lab.git.spikes_repo fetch;

call spike_lab.evidence.probe($run_id, 'P0', 'P0.20',
  'Create dbt project object from Git, pinned to dbt Core 1.11.11',
  $$create or replace dbt project spike_lab.hello.hello
      from '@spike_lab.git.spikes_repo/branches/main/dbt/hello'
      dbt_version = '1.11.11'$$,
  '!ERROR:%');

show dbt projects like 'HELLO' in schema spike_lab.hello;
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.21',
         'New project object is a live-version object (SLD 3.2 prerequisite)',
         'show dbt projects like ''HELLO''', 'LIVE',
         "default_version", iff("default_version" ilike 'LIVE', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct(*)
  from table(result_scan(last_query_id()));

-- Build with the pinned runtime ---------------------------------------------------
-- The EXECUTE DBT PROJECT result row is recorded whole (OBJECT_CONSTRUCT(*)):
-- on this account it has fewer than the four documented columns (spike log).
-- $1 is the success flag and $2 the exception text.
execute dbt project spike_lab.hello.hello args = 'build';
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.22', 'EXECUTE DBT PROJECT build succeeds (pinned 1.11.11)',
         'execute dbt project spike_lab.hello.hello args = ''build''', 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));

call spike_lab.evidence.probe($run_id, 'P0', 'P0.23',
  'Model was built by dbt 1.11.11 (DBT_VERSION pin honoured)',
  $$select dbt_version from spike_lab.hello.hello$$, '1.11.11');

call spike_lab.evidence.probe($run_id, 'P0', 'P0.24',
  'Model was built under the profile role',
  $$select run_role from spike_lab.hello.hello$$, 'SILVER_STEWARD');

-- Per-execution runtime override to 1.12.x (only meaningful if P0.06 passed) -------
-- Adjust the version string to one listed by SYSTEM$SUPPORTED_DBT_VERSIONS().
execute dbt project spike_lab.hello.hello args = 'build' dbt_version = '1.12.3';
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.25', 'EXECUTE DBT PROJECT with DBT_VERSION = 1.12.3 override',
         'execute dbt project ... dbt_version = ''1.12.3''', null,
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         'INFO',
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));

call spike_lab.evidence.probe($run_id, 'P0', 'P0.26',
  'Runtime that built the model after the 1.12.3 override',
  $$select dbt_version from spike_lab.hello.hello$$, null);

-- Evidence ---------------------------------------------------------------------
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
