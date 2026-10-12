-- =============================================================================
-- Prototype / Increment 2 / Step 30: deploy the Silver dbt project object
--
-- ONE live-version dbt project object for every Silver unit (SLD 3.1):
--   silver.ops.silver_layer, from this repository's dbt/silver, dbt Core 1.12.3
-- First deployment: CREATE. Every later deployment: ALTER ... ADD VERSION, which keeps the
-- object's grants (LLD 01, F8; spike S8g). Never CREATE OR REPLACE (drops grants).
-- USAGE on the object goes to SILVER_UNIT_BASE once, so every unit role can execute it.
-- Logs DEPLOYED for each configured Silver unit (gate condition 2, SLD 12.5).
--
-- Trial shortcuts: the steward deploys interactively (production: the pipeline, IA-5,
-- CD-1); Git access through a personal access token (T4).
--
-- Run as: SYSADMIN (repository read), then SILVER_STEWARD. Requires: 00_git_integration,
-- i1_40, i2_20. Idempotent. Set $git_ref first.
-- =============================================================================

use secondary roles none;
set git_ref = 'main';   -- the branch holding dbt/silver; an unmerged branch also works, e.g. 'claude/dazzling-sagan-ludxca'
set run_id = (select uuid_string());

-- The owner of the project object reads the repository (SYSADMIN owns the Git objects)
use role sysadmin;
use warehouse lld_wh;
grant usage on database lld_lab                       to role silver_steward;
grant usage on schema lld_lab.git                     to role silver_steward;
grant read on git repository lld_lab.git.lld_repo     to role silver_steward;
alter git repository lld_lab.git.lld_repo fetch;

use role silver_steward;

-- CREATE the first time (a no-op afterwards), then ADD VERSION: every run deploys the files at
-- $git_ref. On the very first run the object therefore gets two identical versions, which is
-- harmless and keeps the script free of branching on session variables.
-- The branch name is double-quoted in the path: a name with a slash ('claude/...') is otherwise
-- read as a branch 'claude' and a folder (first run 2026-10-12). Quoting is harmless for 'main'.
set from_path = (select '''@lld_lab.git.lld_repo/branches/"' || $git_ref || '"/dbt/silver''');
set create_sql = (select 'create dbt project if not exists silver.ops.silver_layer from ' || $from_path || ' dbt_version = ''1.12.3''');
set add_sql    = (select 'alter dbt project silver.ops.silver_layer add version from ' || $from_path);
execute immediate $create_sql;
execute immediate $add_sql;

grant usage on dbt project silver.ops.silver_layer to role silver_unit_base;

-- DEPLOYED event for every publishable Silver unit (SLD 12.2)
insert into analytics_ops.control.publish_log (unit, event_type, run_id, detail)
  select u.unit, 'DEPLOYED', $run_id, object_construct('git_ref', $git_ref, 'object', 'silver.ops.silver_layer')
  from analytics_ops.control.units u
  where u.unit like 'silver.%';

-- Checks ------------------------------------------------------------------------------
show dbt projects like 'SILVER_LAYER' in schema silver.ops;
set obs = (select nvl(max("default_version"), '<none>') from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.01', 'The Silver project object is live-version',
  'show dbt projects like ''SILVER_LAYER''', 'LIVE', $obs);
show grants on dbt project silver.ops.silver_layer;
set obs = (select listagg("privilege" || ' TO ' || "grantee_name", ',') within group (order by "grantee_name")
           from table(result_scan(last_query_id())) where "privilege" <> 'OWNERSHIP');
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.02', 'USAGE on the project object is held by SILVER_UNIT_BASE (kept across ADD VERSION)',
  'show grants on dbt project silver.ops.silver_layer', '%USAGE TO SILVER_UNIT_BASE%', $obs);

select case_id, outcome, description, observed
from lld_lab.evidence.observation where run_id = $run_id order by case_id;
