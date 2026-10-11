-- =============================================================================
-- Spike S6, part A: the overrides in the dev target, and the canonical state to test against
-- See README.md in this folder.
--
-- SLD 10.4, 10.5, 14 (S6): generate_schema_name, ref and source overrides must work across
-- dev, CI and prod; CI selects with state:modified and defers to the canonical state.
--
--   1  a publication of the ERP unit through the procedure: records the canonical state
--      (query id Q0) of the code CURRENTLY deployed. Part B deploys a changed model and
--      tests state:modified against Q0.
--   2  the dev target: the steward builds the ERP unit in dev_erp (freeze, build): the objects
--      land in the developer's schemas, views keep bare identifiers, and the published
--      schema is untouched.
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, SILVER_STEWARD (switches itself). About 5 minutes.
-- Run BEFORE s06b, and before the PR carrying the S6 change is deployed (it only matters when
-- ADD VERSION runs in s06b, so merging the PR first is fine).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Developer access: the steward reads raw (masked: the policy reveals only platform and unit roles)
use role platform_ingest;
grant usage on schema raw.erp to role silver_steward;
grant select on table raw.erp.accounts to role silver_steward;
grant select on table raw.erp.orders   to role silver_steward;
call raw.control.land_batch('ERP', false);

-- 1: publish through the procedure: the canonical state Q0 ----------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.01', 'Publish the ERP unit (canonical state of the deployed code)', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
set q0 = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.02', 'Canonical state query id Q0 (used by s06b)', 'select ''' || $q0 || '''', null);
set sql_locate = (select 'select system$locate_dbt_artifacts(''' || $q0 || ''')');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.03', 'Q0 can be located', $sql_locate, null);

-- Baseline of the published schema (object names and last-altered times)
set base_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');

-- 2: the dev target ---------------------------------------------------------------------------------
use role silver_steward;
drop schema if exists silver.dev_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');
set dev_freeze = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources --args "{unit: erp, watermark: '
  || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" --target dev --target-path target/dev --log-path logs/dev''');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.10', 'dev: freeze into the developer schema (no publish_unit variable)', $dev_freeze, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.11', 'dev: build the ERP unit',
  $$execute dbt project silver.ops.silver_layer args = 'build --selector unit_erp --target dev --target-path target/dev --log-path logs/dev'$$, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.12', 'dev: objects land in silver.dev_erp (not in silver.erp or an erp__build schema)',
  $$select listagg(table_name, ', ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'DEV_ERP'$$, null);
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.13', 'dev: a base view keeps its bare identifier (S1 rule)',
  $$select iff(contains(get_ddl('view', 'silver.dev_erp.stg_erp__orders'), 'from raw__orders'), 'BARE', 'QUALIFIED')$$, 'BARE');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.14', 'dev: the table reads the dev view, not the published one',
  $$select iff(count(*) > 0, 'ROWS', 'EMPTY') from silver.dev_erp.erp_accounts$$, 'ROWS');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.15', 'dev: PII is masked for the developer (the steward role)',
  $$select email from silver.dev_erp.erp_accounts where account_id = 1$$, '***MASKED***');

use role svc_silver_erp;
set after_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a.17', 'The published ERP schema was not touched by the dev run',
  'select iff(''' || $base_pub || ''' = ''' || $after_pub || ''', ''UNTOUCHED'', ''CHANGED'')', 'UNTOUCHED');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
