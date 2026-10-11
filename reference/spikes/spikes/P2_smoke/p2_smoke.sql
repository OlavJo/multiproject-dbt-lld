-- =============================================================================
-- Phase 2 smoke test: the publish procedure's steps (SLD 10.4), run BY HAND
-- See README.md in this folder.
--
-- Before the publish procedure and spikes S3, S6, S8 and S4 are built on it,
-- confirm that each step works as plain statements:
--   clone the published schema -> freeze (run-operation) -> build (selector) ->
--   audit -> grant/swap/revoke -> consumer reads.
-- Two rounds: round 2 lands a new batch first, so the incremental model, the
-- freeze at a new watermark and a second swap are all exercised.
-- Requires setup/06 and setup/07 (git_ref pointing at a branch holding dbt/silver).
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, ANALYST_TIER1 (the script switches).
-- Not idempotent in its expectations: it assumes the state left by setup/06
-- (2 ERP batches landed, nothing published). Rerun setup/06 first to repeat it.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- ============================ Round 1 ==========================================
use role svc_silver_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');

-- Step 2 (SLD 10.4): build schema as a managed-access clone of the published schema (S2)
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.00', 'Round 1: clone published schema to build schema',
  $$create or replace schema silver.erp__build clone silver.erp with managed access$$, '!ERROR:%');

-- Step 3: freeze at the watermark (run-operation). ARGS is built dynamically.
set freeze_sql = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources '
  || '--args "{unit: erp, watermark: ' || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" '
  || '--vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''');
execute immediate $freeze_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S1.01', 'Round 1: freeze_sources run-operation via EXECUTE IMMEDIATE', $freeze_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.02', 'Round 1: frozen accounts in the build schema (transient clone)',
  $$select count(*) from silver.erp__build.raw__accounts$$, '4');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.03', 'Round 1: frozen orders rows',
  $$select count(*) from silver.erp__build.raw__orders$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.04', 'Round 1: frozen tables are transient',
  $$select listagg(distinct is_transient, ',') from silver.information_schema.tables where table_schema = 'ERP__BUILD' and table_name like 'RAW__%'$$, 'YES');

-- Step 4: source tests, build, output tests in one dbt build with the unit selector
set build_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_erp --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''';
execute immediate $build_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S1.05', 'Round 1: dbt build --selector unit_erp succeeds', $build_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));

-- Audit the build schema before publishing
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.06', 'Round 1: current-state rows in the build schema (one per order)',
  $$select count(*) from silver.erp__build.erp_orders_current$$, '4');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.07', 'Round 1: order 1 is at its latest version (CDC order by source seq)',
  $$select status from silver.erp__build.erp_orders_current where order_id = 1$$, 'RETURNED');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.08', 'Round 1: base view in the build schema uses a bare identifier (S1 rule)',
  $$select get_ddl('view', 'silver.erp__build.stg_erp__orders')$$, '%from raw__orders%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.09', 'Round 1: base view reads the frozen input before the swap',
  $$select count(*) from silver.erp__build.stg_erp__orders$$, '6');

-- Step 5: atomic publish, with the grant, swap, revoke sequence established by S2
grant usage on schema silver.erp__build to database role silver.reader;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.10', 'Round 1: swap build schema with published schema',
  $$alter schema silver.erp__build swap with silver.erp$$, '!ERROR:%');
revoke usage on schema silver.erp__build from database role silver.reader;

-- Consumer view of the published unit
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.11', 'Round 1: published base view reads the swapped frozen input',
  $$select count(*) from silver.erp.stg_erp__orders$$, '6');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.12', 'Round 1: consumer reads published current-state table',
  $$select count(*) from silver.erp.erp_orders_current$$, '4');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.13', 'Round 1: consumer sees PII masked in a materialised model (propagation)',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.14', 'Round 1: consumer cannot read the frozen input',
  $$select count(*) from silver.erp.raw__orders$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S1.15', 'Round 1: consumer cannot read the build schema',
  $$select count(*) from silver.erp__build.erp_orders_current$$, 'ERROR:%');

-- ============================ Round 2 ==========================================
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');

-- Step 2 (SLD 10.4): build schema as a managed-access clone of the published schema (S2)
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.00', 'Round 2: clone published schema to build schema',
  $$create or replace schema silver.erp__build clone silver.erp with managed access$$, '!ERROR:%');

-- Step 3: freeze at the watermark (run-operation). ARGS is built dynamically.
set freeze_sql = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources '
  || '--args "{unit: erp, watermark: ' || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3') || '}" '
  || '--vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''');
execute immediate $freeze_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S2.01', 'Round 2: freeze_sources run-operation via EXECUTE IMMEDIATE', $freeze_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.02', 'Round 2: frozen accounts in the build schema (transient clone)',
  $$select count(*) from silver.erp__build.raw__accounts$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.03', 'Round 2: frozen orders rows',
  $$select count(*) from silver.erp__build.raw__orders$$, '9');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.04', 'Round 2: frozen tables are transient',
  $$select listagg(distinct is_transient, ',') from silver.information_schema.tables where table_schema = 'ERP__BUILD' and table_name like 'RAW__%'$$, 'YES');

-- Step 4: source tests, build, output tests in one dbt build with the unit selector
set build_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_erp --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp''';
execute immediate $build_sql;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.S2.05', 'Round 2: dbt build --selector unit_erp succeeds', $build_sql, 'true',
         iff($1::boolean, 'true', 'ERROR: ' || nvl($2::varchar, '<no exception text>')),
         iff($1::boolean, 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct('query_id', last_query_id(), 'result', object_construct(*))
  from table(result_scan(last_query_id()));

-- Audit the build schema before publishing
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.06', 'Round 2: current-state rows in the build schema (one per order)',
  $$select count(*) from silver.erp__build.erp_orders_current$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.07', 'Round 2: order 1 is at its latest version (CDC order by source seq)',
  $$select status from silver.erp__build.erp_orders_current where order_id = 1$$, 'SHIPPED');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.08', 'Round 2: base view in the build schema uses a bare identifier (S1 rule)',
  $$select get_ddl('view', 'silver.erp__build.stg_erp__orders')$$, '%from raw__orders%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.09', 'Round 2: base view reads the frozen input before the swap',
  $$select count(*) from silver.erp__build.stg_erp__orders$$, '9');

-- Step 5: atomic publish, with the grant, swap, revoke sequence established by S2
grant usage on schema silver.erp__build to database role silver.reader;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.10', 'Round 2: swap build schema with published schema',
  $$alter schema silver.erp__build swap with silver.erp$$, '!ERROR:%');
revoke usage on schema silver.erp__build from database role silver.reader;

-- Consumer view of the published unit
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.11', 'Round 2: published base view reads the swapped frozen input',
  $$select count(*) from silver.erp.stg_erp__orders$$, '9');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.12', 'Round 2: consumer reads published current-state table',
  $$select count(*) from silver.erp.erp_orders_current$$, '6');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.13', 'Round 2: consumer sees PII masked in a materialised model (propagation)',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.14', 'Round 2: consumer cannot read the frozen input',
  $$select count(*) from silver.erp.raw__orders$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.S2.15', 'Round 2: consumer cannot read the build schema',
  $$select count(*) from silver.erp__build.erp_orders_current$$, 'ERROR:%');

-- Evidence ---------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
