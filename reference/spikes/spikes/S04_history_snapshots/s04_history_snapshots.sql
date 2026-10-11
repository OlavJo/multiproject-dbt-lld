-- =============================================================================
-- Spike S4: snapshots and CDC history under clone-build-discard-retry
-- See README.md in this folder.
--
-- SLD 6.7, 14 S4: (1) a CDC history model is correct from the source ordering column;
-- (2) a snapshot's validity timestamps are the unit watermark, not the build's clock, so a
-- build that is discarded and retried stamps the same time; (3) both survive the publish
-- cycle (every build starts as a clone of the last good state).
--
--   Part A  four batches through the publish procedure (unit silver.s4):
--             B1 inserts and an update; B2 an update, an insert and a delete;
--             B3 a redelivered change and a LATE change (lower ordering value, later arrival);
--             B4 a change in the full-load customers table
--           after each: history versions per key, contiguity, current state, snapshot rows and
--           their validity stamps against the published watermark
--   Part B  clone-build-discard-retry by direct calls: a build that fails after the snapshot ran,
--           discarded, re-cloned, re-frozen at the same watermark and built again: are the
--           snapshot and the history identical?
--   Part C  negative control: tamper with the history in a build schema; the history test must fail
--   Part D  the publication of B4 through the procedure, and the final state
-- Requires setup/09, a redeploy of the project (setup/07), and the S3 helper tables are not needed.
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, SILVER_STEWARD (the script switches roles).
-- About 12 minutes. Resets silver.s4 at the start.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Reset the unit and the raw data ----------------------------------------------------------------
use role svc_silver_erp;
drop schema if exists silver.s4__build;
drop schema if exists silver.s4;
create schema silver.s4 with managed access;
grant usage on schema silver.s4 to database role silver.reader;
use role platform_ingest;
truncate table raw.s4.orders_cdc;
truncate table raw.s4.customers;

-- =============================================================================
-- Part A, batch 1: order 1 inserted and updated, order 2 inserted; three customers
-- =============================================================================
insert into raw.s4.orders_cdc (order_id, status, amount, _op, _seq, _commit_ts) values
  (1, 'NEW',  100.00, 'I', 10, '2026-01-01 10:01:00'),
  (2, 'NEW',   50.00, 'I', 20, '2026-01-01 10:02:00'),
  (1, 'PAID', 100.00, 'U', 30, '2026-01-01 10:03:00');
insert into raw.s4.customers (customer_id, name, tier) values (1, 'Ann', 'gold'), (2, 'Bob', 'silver'), (3, 'Cy', 'bronze');
call raw.control.land_batch('S4', true);

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.00', 'B1: publish the unit', $$call silver.ops.publish_unit('silver.s4')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.01', 'B1: history rows (order 1: 2 versions, order 2: 1)', $$select count(*) from silver.s4.s4_orders_history$$, '3');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.02', 'B1: order 1 versions, contiguous, last open',
  $$select listagg(source_seq || ':' || to_varchar(valid_from, 'HH24:MI:SS') || '-' || nvl(to_varchar(valid_to, 'HH24:MI:SS'), 'open'), ', ') within group (order by source_seq) from silver.s4.s4_orders_history where order_id = 1$$,
  '10:10:01:00-10:03:00, 30:10:03:00-open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.03', 'B1: current state rows', $$select count(*) from silver.s4.s4_orders_current$$, '2');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.04', 'B1: snapshot rows, all open', $$select count(*) || ' rows, ' || count_if(dbt_valid_to is null) || ' open' from silver.s4.s4_customers_snapshot$$, '3 rows, 3 open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A1.05', 'B1: snapshot validity is the published watermark, not the clock',
  $$select iff(count(distinct dbt_valid_from) = 1 and abs(datediff('millisecond', max(dbt_valid_from), (select watermark from analytics_ops.control.publish_log where unit = 'silver.s4' and event_type = 'PUBLISHED' order by event_ts desc limit 1))) <= 1, 'WATERMARK', 'OTHER') from silver.s4.s4_customers_snapshot$$,
  'WATERMARK');

-- =============================================================================
-- Part A, batch 2: order 1 updated, order 3 inserted, order 2 deleted; customer 1 changes
-- tier, customer 2 is deleted, customer 4 is new
-- =============================================================================
use role platform_ingest;
insert into raw.s4.orders_cdc (order_id, status, amount, _op, _seq, _commit_ts) values
  (1, 'SHIPPED', 100.00, 'U', 50, '2026-01-01 10:05:00'),
  (3, 'NEW',      75.00, 'I', 60, '2026-01-01 10:06:00'),
  (2, 'NEW',      50.00, 'D', 70, '2026-01-01 10:07:00');
update raw.s4.customers set tier = 'platinum' where customer_id = 1;
delete from raw.s4.customers where customer_id = 2;
insert into raw.s4.customers (customer_id, name, tier) values (4, 'Di', 'gold');
call raw.control.land_batch('S4', true);

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.00', 'B2: publish the unit', $$call silver.ops.publish_unit('silver.s4')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.01', 'B2: history rows (3 + 2 + 1)', $$select count(*) from silver.s4.s4_orders_history$$, '6');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.02', 'B2: order 1 has three versions, each closing when the next opens',
  $$select listagg(source_seq || ':' || to_varchar(valid_from, 'HH24:MI:SS') || '-' || nvl(to_varchar(valid_to, 'HH24:MI:SS'), 'open'), ', ') within group (order by source_seq) from silver.s4.s4_orders_history where order_id = 1$$,
  '10:10:01:00-10:03:00, 30:10:03:00-10:05:00, 50:10:05:00-open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.03', 'B2: order 2: the insert version closed by the delete tombstone, which stays open and is flagged',
  $$select listagg(source_seq || ':' || op || ':' || is_deleted::varchar || ':' || nvl(to_varchar(valid_to, 'HH24:MI:SS'), 'open'), ', ') within group (order by source_seq) from silver.s4.s4_orders_history where order_id = 2$$,
  '20:I:false:10:07:00, 70:D:true:open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.04', 'B2: current state excludes the deleted order', $$select listagg(order_id, ',') within group (order by order_id) from silver.s4.s4_orders_current$$, '1,3');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.05', 'B2: snapshot rows (customer 1 twice, customer 2 closed, 3, 4)', $$select count(*) || ' rows, ' || count_if(dbt_valid_to is null) || ' open' from silver.s4.s4_customers_snapshot$$, '5 rows, 3 open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.06', 'B2: customer 1: the old version closes exactly when the new one opens, at the published watermark',
  $$select iff(count(*) = 1 and abs(datediff('millisecond', max(o.dbt_valid_to), (select watermark from analytics_ops.control.publish_log where unit = 'silver.s4' and event_type = 'PUBLISHED' order by event_ts desc limit 1))) <= 1, 'MATCH', 'MISMATCH') from silver.s4.s4_customers_snapshot o join silver.s4.s4_customers_snapshot n on n.customer_id = o.customer_id and n.dbt_valid_from = o.dbt_valid_to and n.dbt_valid_to is null where o.customer_id = 1$$,
  'MATCH');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A2.07', 'B2: the deleted customer is closed at the same watermark (hard delete invalidated)',
  $$select iff(dbt_valid_to = (select dbt_valid_from from silver.s4.s4_customers_snapshot where customer_id = 1 and dbt_valid_to is null), 'CLOSED_AT_WATERMARK', 'OTHER') from silver.s4.s4_customers_snapshot where customer_id = 2$$,
  'CLOSED_AT_WATERMARK');

-- =============================================================================
-- Part A, batch 3: a redelivered change (order 1, seq 50) and a LATE change
-- (order 1, seq 40, committed 10:04, arriving after seq 50)
-- =============================================================================
use role platform_ingest;
insert into raw.s4.orders_cdc (order_id, status, amount, _op, _seq, _commit_ts) values
  (1, 'SHIPPED', 100.00, 'U', 50, '2026-01-01 10:05:00'),
  (1, 'PAID',    110.00, 'U', 40, '2026-01-01 10:04:00');
call raw.control.land_batch('S4', true);

use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.00', 'B3: publish the unit', $$call silver.ops.publish_unit('silver.s4')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.01', 'B3: history rows (one more: the late version; the redelivery adds none)', $$select count(*) from silver.s4.s4_orders_history$$, '7');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.02', 'B3: order 1: the late change slots in by ordering value and re-closes its neighbour',
  $$select listagg(source_seq || ':' || to_varchar(valid_from, 'HH24:MI:SS') || '-' || nvl(to_varchar(valid_to, 'HH24:MI:SS'), 'open'), ', ') within group (order by source_seq) from silver.s4.s4_orders_history where order_id = 1$$,
  '10:10:01:00-10:03:00, 30:10:03:00-10:04:00, 40:10:04:00-10:05:00, 50:10:05:00-open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.03', 'B3: the redelivered change is stored once', $$select count(*) from silver.s4.s4_orders_history where order_id = 1 and source_seq = 50$$, '1');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.04', 'B3: current state is still the latest by ordering value (the late change does not become current)',
  $$select status from silver.s4.s4_orders_current where order_id = 1$$, 'SHIPPED');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.A3.05', 'B3: snapshot unchanged (no customer change)', $$select count(*) || ' rows, ' || count_if(dbt_valid_to is null) || ' open' from silver.s4.s4_customers_snapshot$$, '5 rows, 3 open');

-- =============================================================================
-- Part A, batch 4 lands (customer 3 changes tier); NOT yet published: Parts B and C use it
-- =============================================================================
use role platform_ingest;
update raw.s4.customers set tier = 'gold' where customer_id = 3;
call raw.control.land_batch('S4', true);

-- =============================================================================
-- Part B: clone-build-discard-retry by direct calls (the procedure's steps 2 to 4)
-- =============================================================================
use role svc_silver_erp;
set wm = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'S4');
set freeze_sql = (select 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources --args "{unit: s4, watermark: '
  || to_varchar($wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3')
  || '}" --vars "{publish_unit: s4}" --target prod_s4 --target-path target/s4 --log-path logs/s4''');
set build_ok_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_s4 --vars "{publish_unit: s4}" --target prod_s4 --target-path target/s4 --log-path logs/s4''';
set build_fail_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_s4 --vars "{publish_unit: s4, inject_failure: output_test}" --target prod_s4 --target-path target/s4 --log-path logs/s4''';

-- Attempt 1: clone, freeze, a build that fails AFTER the snapshot ran (an output test fails)
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B1.00', 'Attempt 1: clone the published schema', $$create or replace schema silver.s4__build clone silver.s4 with managed access$$, '!ERROR:%');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B1.01', 'Attempt 1: freeze at the batch-4 watermark', $freeze_sql, 'true');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B1.02', 'Attempt 1: build with an output test that fails', $build_fail_sql, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B1.03', 'Attempt 1: did the failed build write the new snapshot version? (customer 3 versions in the build schema)',
  $$select count(*) from silver.s4__build.s4_customers_snapshot where customer_id = 3$$, null);
set h1 = (select md5(listagg(customer_id || ':' || tier || ':' || to_varchar(dbt_valid_from, 'YYYY-MM-DD HH24:MI:SS.FF3') || ':' || nvl(to_varchar(dbt_valid_to, 'YYYY-MM-DD HH24:MI:SS.FF3'), 'open'), ',') within group (order by customer_id, dbt_valid_from)) from silver.s4__build.s4_customers_snapshot);
set hh1 = (select md5(listagg(order_id || ':' || source_seq || ':' || to_varchar(valid_from) || ':' || nvl(to_varchar(valid_to), 'open'), ',') within group (order by order_id, source_seq)) from silver.s4__build.s4_orders_history);
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B1.04', 'Attempt 1: fingerprint of the snapshot and of the history in the discarded build schema',
  'select ''snapshot='' || ''' || $h1 || ''' || '' history='' || ''' || $hh1 || '''', null);

-- Discard and retry at the SAME watermark: re-clone the last good state, re-freeze, build
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.00', 'Retry: discard and clone the published schema again', $$create or replace schema silver.s4__build clone silver.s4 with managed access$$, '!ERROR:%');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.01', 'Retry: freeze at the same watermark', $freeze_sql, 'true');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.02', 'Retry: build succeeds', $build_ok_sql, 'true');
set h2 = (select md5(listagg(customer_id || ':' || tier || ':' || to_varchar(dbt_valid_from, 'YYYY-MM-DD HH24:MI:SS.FF3') || ':' || nvl(to_varchar(dbt_valid_to, 'YYYY-MM-DD HH24:MI:SS.FF3'), 'open'), ',') within group (order by customer_id, dbt_valid_from)) from silver.s4__build.s4_customers_snapshot);
set hh2 = (select md5(listagg(order_id || ':' || source_seq || ':' || to_varchar(valid_from) || ':' || nvl(to_varchar(valid_to), 'open'), ',') within group (order by order_id, source_seq)) from silver.s4__build.s4_orders_history);
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.03', 'Retry: snapshot identical to the failed attempt? (same validity stamps)',
  'select iff(''' || $h1 || ''' = ''' || $h2 || ''', ''IDENTICAL'', ''DIFFERENT'')', 'IDENTICAL');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.04', 'Retry: history identical to the failed attempt?',
  'select iff(''' || $hh1 || ''' = ''' || $hh2 || ''', ''IDENTICAL'', ''DIFFERENT'')', 'IDENTICAL');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.B2.05', 'Retry: customer 3 has two versions, the new one stamped with the batch-4 watermark',
  'select count(*) || '' versions; new valid_from is the watermark: '' || iff(abs(datediff(''millisecond'', max(iff(dbt_valid_to is null, dbt_valid_from, null)), ''' || to_varchar($wm, 'YYYY-MM-DD HH24:MI:SS.FF3') || '''::timestamp_ntz)) <= 1, ''yes'', ''no'') from silver.s4__build.s4_customers_snapshot where customer_id = 3',
  '2 versions; new valid_from is the watermark: yes');

-- =============================================================================
-- Part C: negative control: the history test must catch a broken history
-- =============================================================================
update silver.s4__build.s4_orders_history set valid_to = dateadd(minute, 1, valid_to) where order_id = 1 and source_seq = 30;
call spike_lab.evidence.probe($run_id, 'S4', 'S4.C1.00', 'Tampered history (a version closes a minute late): the history test fails',
  'execute dbt project silver.ops.silver_layer args = ''test --select s4_orders_history --vars "{publish_unit: s4}" --target prod_s4 --target-path target/s4 --log-path logs/s4''',
  'ERROR:%history_contiguous%');
drop schema if exists silver.s4__build;

-- =============================================================================
-- Part D: publish batch 4 through the procedure; final state
-- =============================================================================
call spike_lab.evidence.probe($run_id, 'S4', 'S4.D1.00', 'B4: publish the unit', $$call silver.ops.publish_unit('silver.s4')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.D1.01', 'B4: snapshot rows (customer 3 now has two versions)', $$select count(*) || ' rows, ' || count_if(dbt_valid_to is null) || ' open' from silver.s4.s4_customers_snapshot$$, '6 rows, 3 open');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.D1.02', 'B4: the new version of customer 3 is stamped with the published watermark',
  $$select iff(abs(datediff('millisecond', dbt_valid_from, (select watermark from analytics_ops.control.publish_log where unit = 'silver.s4' and event_type = 'PUBLISHED' order by event_ts desc limit 1))) <= 1, 'WATERMARK', 'OTHER') from silver.s4.s4_customers_snapshot where customer_id = 3 and dbt_valid_to is null$$,
  'WATERMARK');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.D1.03', 'B4: history unchanged by a customers-only batch', $$select count(*) from silver.s4.s4_orders_history$$, '7');
call spike_lab.evidence.probe($run_id, 'S4', 'S4.D1.04', 'Table kinds: history and snapshot are permanent, the current state is transient',
  $$select listagg(table_name || '=' || is_transient, ', ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'S4' and table_name in ('S4_ORDERS_HISTORY', 'S4_CUSTOMERS_SNAPSHOT', 'S4_ORDERS_CURRENT')$$,
  'S4_CUSTOMERS_SNAPSHOT=NO, S4_ORDERS_CURRENT=YES, S4_ORDERS_HISTORY=NO');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
