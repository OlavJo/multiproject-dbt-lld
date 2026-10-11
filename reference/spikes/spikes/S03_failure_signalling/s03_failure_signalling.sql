-- =============================================================================
-- Spike S3: failure signalling from EXECUTE DBT PROJECT
-- See README.md in this folder.
--
-- SLD 3.1 / 10.4: EXECUTE DBT PROJECT is documented to return FALSE in its success
-- column rather than raise. The publish procedure must read that result before
-- every next step. Question: is the result reliable for build, run-operation,
-- compile and source freshness, for test failures, warehouse errors and compile
-- errors; and does the procedure then fail safe (nothing published, lease
-- released, FAILED logged with enough to attribute it)?
--
--   Part A  dbt-level, by direct calls through a helper that records the whole
--           outcome (raised or returned; success flag; exception text; STDOUT tail).
--           Failures are injected with --vars '{inject_failure: <kind>}' (dbt/silver).
--   Part B  procedure-level, with failures caused in raw (data-driven):
--             B1 a source test fails (null key landed)
--             B2 the freeze fails (a raw table is missing)
--             B3 the build fails (a raw column is renamed: schema drift)
--           each followed by recovery. Nothing published may change on a failure.
--
-- Requires setup/08 (fixed) and the state of p3 scripts. ERP only.
-- Run as: SYSADMIN (helper), SVC_SILVER_ERP, PLATFORM_INGEST, ANALYST_TIER1,
-- SILVER_STEWARD (final query). The script switches roles itself.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Helper: run one EXECUTE DBT PROJECT call, record the whole outcome ------------------
use role sysadmin;
create or replace procedure spike_lab.evidence.run_dbt(
    p_run_id varchar, p_case varchar, p_desc varchar, p_args varchar, p_expect_success boolean)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_sql    varchar;
  v_ok     boolean;
  v_exc    varchar;
  v_out    varchar;
  v_raised boolean default false;
  v_err    varchar;
  v_qid    varchar;
begin
  v_sql := 'execute dbt project silver.ops.silver_layer args = ''' || replace(p_args, '''', '''''') || '''';
  begin
    execute immediate :v_sql;
    select last_query_id() into :v_qid;
    select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
      from table(result_scan(:v_qid));
  exception
    when other then
      v_raised := true;
      v_err := sqlerrm;
  end;
  insert into spike_lab.evidence.observation
    select :p_run_id, 'S3', :p_case, :p_desc, :v_sql,
           iff(:p_expect_success, 'success=true', 'success=false'),
           iff(:v_raised, 'RAISED: ' || :v_err, 'success=' || nvl(:v_ok::varchar, 'null')),
           iff(:v_raised, 'FAIL', iff(coalesce(:v_ok = :p_expect_success, false), 'PASS', 'FAIL')),
           current_role(), current_secondary_roles(), sysdate(), current_version(),
           object_construct('query_id', :v_qid, 'raised', :v_raised, 'error', :v_err,
                            'success', :v_ok, 'exception', :v_exc, 'stdout_tail', right(:v_out, 2500));
  return iff(:v_raised, 'RAISED', 'success=' || nvl(:v_ok::varchar, 'null'));
end;
$$;
grant usage on procedure spike_lab.evidence.run_dbt(varchar, varchar, varchar, varchar, boolean) to role svc_silver_erp;

-- =============================================================================
-- Part A: dbt-level outcomes
-- =============================================================================
use role svc_silver_erp;

-- A00: a build schema holding frozen inputs, as the procedure leaves it before step 4
call spike_lab.evidence.probe($run_id, 'S3', 'S3.A00a', 'Setup: managed-access clone of the published schema',
  $$create or replace schema silver.erp__build clone silver.erp with managed access$$, '!ERROR:%');
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP');
set freeze_args = (select 'run-operation freeze_sources --args "{unit: erp, watermark: '
  || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3')
  || '}" --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp');
call spike_lab.evidence.run_dbt($run_id, 'S3.A00b', 'Setup: run-operation freeze_sources succeeds', $freeze_args, true);

-- A01 to A06: build outcomes
call spike_lab.evidence.run_dbt($run_id, 'S3.A01', 'build: everything passes',
  'build --selector unit_erp --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp', true);
call spike_lab.evidence.run_dbt($run_id, 'S3.A02', 'build: a model fails in the warehouse (division by zero)',
  'build --selector unit_erp --vars "{publish_unit: erp, inject_failure: sql_error}" --target prod_erp --target-path target/erp --log-path logs/erp', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A03', 'build: an output test at error severity fails',
  'build --selector unit_erp --vars "{publish_unit: erp, inject_failure: output_test}" --target prod_erp --target-path target/erp --log-path logs/erp', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A04', 'build: a test at warn severity fails (warning only)',
  'build --selector unit_erp --vars "{publish_unit: erp, inject_failure: warn_test}" --target prod_erp --target-path target/erp --log-path logs/erp', true);
call spike_lab.evidence.run_dbt($run_id, 'S3.A05', 'build: a jinja compile error in a model',
  'build --selector unit_erp --vars "{publish_unit: erp, inject_failure: compile_error}" --target prod_erp --target-path target/erp --log-path logs/erp', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A06', 'build: the selector does not exist',
  'build --selector unit_nope --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp', false);

-- A07 to A09: run-operation outcomes
call spike_lab.evidence.run_dbt($run_id, 'S3.A07', 'run-operation: the macro raises (no tables declared for the unit)',
  'run-operation freeze_sources --args "{unit: nope, watermark: 2026-01-01T00:00:00.000}" --vars "{publish_unit: nope}" --target prod_erp --target-path target/erp --log-path logs/erp', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A08', 'run-operation: the macro does not exist',
  'run-operation no_such_macro --target prod_erp --target-path target/erp --log-path logs/erp', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A09', 'run-operation: the clone fails in the warehouse (watermark before the table existed)',
  'run-operation freeze_sources --args "{unit: erp, watermark: 2020-01-01T00:00:00.000}" --vars "{publish_unit: erp}" --target prod_erp --target-path target/erp --log-path logs/erp', false);

-- A10 to A12: compile and freshness
call spike_lab.evidence.run_dbt($run_id, 'S3.A10', 'compile: succeeds',
  'compile --target prod_erp --target-path target/canonical --log-path logs/canonical', true);
call spike_lab.evidence.run_dbt($run_id, 'S3.A11', 'compile: a jinja compile error',
  'compile --vars "{inject_failure: compile_error}" --target prod_erp --target-path target/canonical --log-path logs/canonical', false);
call spike_lab.evidence.run_dbt($run_id, 'S3.A12', 'source freshness on the live raw source (loaded_at_query on the landing records)',
  'source freshness --select source:erp_raw --target prod_erp --target-path target/freshness --log-path logs/freshness', true);

-- A13: not a dbt command at all
call spike_lab.evidence.run_dbt($run_id, 'S3.A13', 'not a dbt command',
  'nonsense --target prod_erp', false);

-- =============================================================================
-- Part B: the procedure, with failures caused in raw
-- =============================================================================
-- B0: a clean, known state
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B00', 'Baseline publish through the procedure', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
set n0 = (select count(*) from silver.erp.erp_orders_current);
set q_unchanged = (select 'select iff(count(*) = ' || $n0 || ', ''UNCHANGED'', ''CHANGED'') from silver.erp.erp_orders_current');

-- B1: a source test fails: a row with a null key lands (and a new landing-complete record)
use role platform_ingest;
insert into raw.erp.orders (order_id, account_id, status, amount, _seq) values (null, 1, 'BAD', 1, 99999);
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B10', 'B1: source test fails: the procedure reports the build failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:build');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B11', 'B1: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B12', 'B1: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B13', 'B1: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B14', 'B1: FAILED event: exception text',
  $$select detail:exception::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B15', 'B1: FAILED event: STDOUT tail (does it name the failing source test?)',
  $$select left(detail:stdout_tail::varchar, 1500) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B16', 'B1: consumer still reads masked PII from the last good version',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
use role platform_ingest;
delete from raw.erp.orders where order_id is null;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B17', 'B1: after the bad row is removed and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B2: the freeze fails: a raw table is missing
use role platform_ingest;
alter table raw.erp.orders rename to raw.erp.orders_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B20', 'B2: a raw table is missing: the procedure reports the freeze failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:freeze');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B21', 'B2: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B22', 'B2: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B23', 'B2: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B24', 'B2: FAILED event: exception text and STDOUT tail',
  $$select nvl(detail:exception::varchar, '<null>') || ' | ' || left(nvl(detail:stdout_tail::varchar, '<null>'), 1200) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders_x rename to raw.erp.orders;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B25', 'B2: after the table is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B3: the build fails: a raw column is renamed (schema drift)
use role platform_ingest;
alter table raw.erp.orders rename column status to status_x;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B30', 'B3: a raw column is renamed: the procedure reports the build failure',
  $$call silver.ops.publish_unit('silver.erp')$$, 'FAILED:build');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B31', 'B3: published data unchanged', $q_unchanged, 'UNCHANGED');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B32', 'B3: lease released', $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B33', 'B3: FAILED event: stage and failure class',
  $$select detail:stage::varchar || ' / ' || detail:failure_class::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B34', 'B3: FAILED event: STDOUT tail (does it name the model that failed?)',
  $$select left(detail:stdout_tail::varchar, 1500) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'FAILED' order by event_ts desc limit 1$$, null);
use role platform_ingest;
alter table raw.erp.orders rename column status_x to status;
call raw.control.land_batch('ERP', true);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B35', 'B3: after the column is restored and a new batch lands: recovers',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- B4: state after the failures ---------------------------------------------------------------
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B40', 'Run control: events of the three failed runs and the recoveries',
  $$select listagg(event_type || ':' || nvl(detail:stage::varchar, nvl(detail:reason::varchar, '')), ', ') within group (order by event_ts) from (select * from analytics_ops.control.publish_log where unit = 'silver.erp' order by event_ts desc limit 24)$$, null);
use role silver_steward;   -- the stale-run view is a steward view (unit roles have no grant on it)
call spike_lab.evidence.probe($run_id, 'S3', 'S3.B41', 'Run control: no stale STARTED after the failures',
  $$select count(*) from analytics_ops.control.unit_stale where unit = 'silver.erp' and is_stale$$, '0');

-- Evidence ---------------------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
