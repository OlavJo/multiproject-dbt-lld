-- =============================================================================
-- Spike S8, part 7: deploying with ALTER DBT PROJECT ... ADD VERSION (in place)
-- s08f.10 showed that ADD VERSION is accepted on the live-version object and replaces the
-- files of the live version in place ("Successfully deployed new files to the live version").
-- That deployment was made with no change of content. Open (the s08f script stopped before
-- checking): does an in-place deployment keep (1) the unit roles' grants and (2) the
-- canonical state of earlier executions, both of which CREATE OR REPLACE loses?
--
-- This script, run after the S4 code is on main:
--   1  checks the state left by the first ADD VERSION (grants, object, a canonical execution
--      from BEFORE it, a unit role executing)
--   2  deploys again with ADD VERSION, now with new files (the S4 models and macros)
--   3  checks the same, and that the new code is live (the unit_s4 selector exists)
--   4  logs DEPLOYED for the T0 units (the gate, SLD 12.7)
-- No re-grant is made until the very end, so a lost grant shows as a failure.
-- The canonical execution id 01c78f36-... is from evidence/ (s08f.01), before the first ADD VERSION.
-- Run as: SILVER_STEWARD, SVC_SILVER_ERP (the script switches). About 3 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set git_ref = 'main';
set qid = '01c78f36-0004-2402-0003-5b0a00055d32';
set sql_locate = (select 'select system$locate_dbt_artifacts(''' || $qid || ''')');

-- 1: state after the first ADD VERSION ------------------------------------------------------------
use role silver_steward;
show grants on dbt project silver.ops.silver_layer;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8g.01', 'Grants on the object after the first ADD VERSION (no re-grant)', 'show grants on dbt project', null,
         'rows=' || count(*) || '; grantees=' || nvl(listagg("grantee_name" || ':' || "privilege", ', '), '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), array_agg(object_construct(*))
  from table(result_scan(last_query_id()));
show dbt projects like 'SILVER_LAYER' in schema silver.ops;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8g.02', 'The object after the first ADD VERSION (all columns in DETAIL)', 'show dbt projects', null,
         'default_version=' || "default_version" || '; dbt_version=' || nvl("dbt_version", '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), object_construct(*)
  from table(result_scan(last_query_id()));
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.03', 'Locate the canonical execution from BEFORE the first ADD VERSION', $sql_locate, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.04', 'A unit role executes the object after the first ADD VERSION (grant kept?)',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --target-path target/canonical --log-path logs/canonical'$$, '!ERROR:%');

-- 2: deploy the new files in place -------------------------------------------------------------------
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set sql_add = (select 'alter dbt project silver.ops.silver_layer add version from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.10', 'ADD VERSION with new files (the S4 models and macros)', $sql_add, '!ERROR:%');

-- 3: state after it ------------------------------------------------------------------------------------
show grants on dbt project silver.ops.silver_layer;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8g.11', 'Grants on the object after the second ADD VERSION (no re-grant)', 'show grants on dbt project', null,
         'rows=' || count(*) || '; grantees=' || nvl(listagg("grantee_name" || ':' || "privilege", ', '), '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), array_agg(object_construct(*))
  from table(result_scan(last_query_id()));
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.12', 'Locate the canonical execution from before BOTH deployments', $sql_locate, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.13', 'The new code is live: list the S4 unit (selector unit_s4 exists)',
  $$execute dbt project silver.ops.silver_layer args = 'list --selector unit_s4 --target prod_s4 --vars "{publish_unit: s4}"'$$, '!ERROR:%');
call spike_lab.evidence.probe($run_id, 'S8', 'S8g.14', 'The ERP unit still compiles after the second ADD VERSION',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --target-path target/canonical --log-path logs/canonical'$$, '!ERROR:%');

-- 4: DEPLOYED for the T0 units (the code changed), then restore grants only if they were lost -------------
use role silver_steward;
insert into analytics_ops.control.publish_log (unit, event_type, run_id, detail)
  select u.unit, 'DEPLOYED', $run_id, object_construct('git_ref', $git_ref, 'by', 's08g', 'method', 'add version')
  from analytics_ops.control.units u where u.tier = 'T0';
grant usage on dbt project silver.ops.silver_layer to role svc_silver_erp;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_crm;

select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
