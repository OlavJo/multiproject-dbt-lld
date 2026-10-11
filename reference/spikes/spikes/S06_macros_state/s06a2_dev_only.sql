-- =============================================================================
-- Spike S6, part A2: the dev target again (no publication: Q0 of s06a stays the baseline)
-- s06a run 1: the dev freeze failed because the macro did not create the developer schema (in prod
-- the publish procedure creates the build schema; dev and CI have no such step). The macro now
-- creates the schema in non-prod targets (deployed by s06b's ADD VERSION). This repeats the dev part.
-- Run after s06b. Run as: SILVER_STEWARD, SVC_SILVER_ERP (switches itself). About 2 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role svc_silver_erp;
set base_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');

-- 2: the dev target ---------------------------------------------------------------------------------
use role silver_steward;
drop schema if exists silver.dev_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');
set dev_freeze = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources --args "{unit: erp, watermark: '
  || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" --target dev --target-path target/dev --log-path logs/dev''');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.10', 'dev: freeze into the developer schema (no publish_unit variable)', $dev_freeze, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.11', 'dev: build the ERP unit',
  $$execute dbt project silver.ops.silver_layer args = 'build --selector unit_erp --target dev --target-path target/dev --log-path logs/dev'$$, 'true');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.12', 'dev: objects land in silver.dev_erp (not in silver.erp or an erp__build schema)',
  $$select listagg(table_name, ', ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'DEV_ERP'$$, null);
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.13', 'dev: a base view keeps its bare identifier (S1 rule)',
  $$select iff(contains(get_ddl('view', 'silver.dev_erp.stg_erp__orders'), 'from raw__orders'), 'BARE', 'QUALIFIED')$$, 'BARE');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.14', 'dev: the table reads the dev view, not the published one',
  $$select iff(count(*) > 0, 'ROWS', 'EMPTY') from silver.dev_erp.erp_accounts$$, 'ROWS');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.15', 'dev: PII is masked for the developer (the steward role)',
  $$select email from silver.dev_erp.erp_accounts where account_id = 1$$, '***MASKED***');

use role svc_silver_erp;
set after_pub = (select md5(listagg(table_name || '@' || to_varchar(last_altered, 'YYYY-MM-DD HH24:MI:SS.FF3'), ',') within group (order by table_name)) from silver.information_schema.tables where table_schema = 'ERP');
call spike_lab.evidence.probe($run_id, 'S6', 'S6a2.17', 'The published ERP schema was not touched by the dev run',
  'select iff(''' || $base_pub || ''' = ''' || $after_pub || ''', ''UNTOUCHED'', ''CHANGED'')', 'UNTOUCHED');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
