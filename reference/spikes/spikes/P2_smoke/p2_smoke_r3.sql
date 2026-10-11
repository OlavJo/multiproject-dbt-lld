-- =============================================================================
-- Phase 2 smoke test, round 3: re-tag with PII_DEP and republish ERP (S9f)
-- The smoke test (rounds 1 and 2) showed PII in clear in erp_accounts: the tag
-- PII_DECL propagates on data movement only and stops at the base view (S9f).
-- This round moves the raw column to PII_DEP (propagates through views), then
-- republishes the ERP unit with no new batch (a deployment-style republish),
-- and checks the consumer now sees the email masked.
-- Requires: p2_smoke.sql rounds 1 and 2 run, and setup/05 rerun (creates PII_DEP).
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, ANALYST_TIER1 (the script switches).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role platform_ingest;
alter table raw.erp.accounts modify column email unset tag governance.policies.pii_decl;
alter table raw.erp.accounts modify column email set tag governance.policies.pii_dep = 'email';

-- ============================ Round 3 ==========================================
use role svc_silver_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');

-- Step 2 (SLD 10.4): build schema as a managed-access clone of the published schema (S2)
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.00', 'Round 3: clone published schema to build schema',
  $$create or replace schema silver.erp__build clone silver.erp with managed access$$, '!ERROR:%');

-- Step 3: freeze at the watermark (run-operation). ARGS is built dynamically.
set freeze_sql = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources '
  || '--args "{unit: erp, watermark: ' || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" '
  || '--vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''');
execute immediate $freeze_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S3.01', 'Round 3: freeze_sources run-operation via EXECUTE IMMEDIATE', $freeze_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.02', 'Round 3: frozen accounts in the build schema (transient clone)',
  $$select count(*) from silver.erp__build.raw__accounts$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.03', 'Round 3: frozen orders rows',
  $$select count(*) from silver.erp__build.raw__orders$$, '9');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.04', 'Round 3: frozen tables are transient',
  $$select listagg(distinct is_transient, ',') from silver.information_schema.tables where table_schema = 'ERP__BUILD' and table_name like 'RAW__%'$$, 'YES');

-- Step 4: source tests, build, output tests in one dbt build with the unit selector
set build_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_erp --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''';
execute immediate $build_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S3.05', 'Round 3: dbt build --selector unit_erp succeeds', $build_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));

-- Audit the build schema before publishing
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.06', 'Round 3: current-state rows in the build schema (one per order)',
  $$select count(*) from silver.erp__build.erp_orders_current$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.07', 'Round 3: order 1 is at its latest version (CDC order by source seq)',
  $$select status from silver.erp__build.erp_orders_current where order_id = 1$$, 'SHIPPED');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.08', 'Round 3: base view in the build schema uses a bare identifier (S1 rule)',
  $$select get_ddl('view', 'silver.erp__build.stg_erp__orders')$$, '%from raw__orders%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.09', 'Round 3: base view reads the frozen input before the swap',
  $$select count(*) from silver.erp__build.stg_erp__orders$$, '9');

-- Step 5: atomic publish, with the grant, swap, revoke sequence established by S2
grant usage on schema silver.erp__build to database role silver.reader;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.10', 'Round 3: swap build schema with published schema',
  $$alter schema silver.erp__build swap with silver.erp$$, '!ERROR:%');
revoke usage on schema silver.erp__build from database role silver.reader;

-- Consumer view of the published unit
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.11', 'Round 3: published base view reads the swapped frozen input',
  $$select count(*) from silver.erp.stg_erp__orders$$, '9');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.12', 'Round 3: consumer reads published current-state table',
  $$select count(*) from silver.erp.erp_orders_current$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.13', 'Round 3: consumer sees PII masked in a materialised model (propagation)',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.14', 'Round 3: consumer cannot read the frozen input',
  $$select count(*) from silver.erp.raw__orders$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S3.15', 'Round 3: consumer cannot read the build schema',
  $$select count(*) from silver.erp__build.erp_orders_current$$, 'ERROR:%');

-- Evidence ---------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
