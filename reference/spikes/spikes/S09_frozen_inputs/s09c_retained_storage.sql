-- =============================================================================
-- Spike S9c: retained storage from replaced transient clones (trend only)
-- See README.md in this folder, section S9c.
--
-- SLD 7.4: every unit run replaces its frozen inputs with fresh clones of raw.
-- A replaced clone's micro-partitions that raw has since rewritten are retained
-- for Time Travel. Question: how much is retained, and does a short retention
-- period on the Silver schema contain it?
--
-- Method (one sitting, a few minutes: INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
-- is read directly, and bytes retained depend on churn, not on elapsed time):
--   * Two synthetic raw tables of 2,000,000 rows (~60-byte random payload):
--       S9C_SCATTERED  each cycle rewrites 10% of rows spread across all partitions
--                      (worst case: nearly every micro-partition is rewritten)
--       S9C_CLUSTERED  each cycle rewrites the last 5% of rows only
--                      (append-like churn: a few partitions are rewritten)
--   * Two Silver schemas owned by the unit service role:
--       SILVER.S9C_RET1  DATA_RETENTION_TIME_IN_DAYS = 1
--       SILVER.S9C_RET0  DATA_RETENTION_TIME_IN_DAYS = 0
--   * 6 cycles: churn raw, then replace the frozen clones in both schemas at a
--     UTC NTZ watermark (as the freeze does), then snapshot storage metrics.
--   * The script is generated and unrolled because each phase needs a
--     different role (platform churns raw; the service role freezes).
--
-- Snapshots go to SPIKE_LAB.EVIDENCE.S9C_STORAGE; summary rows go to the
-- observation table at the end. Idempotent: recreates everything it uses.
-- Run as: SYSADMIN (evidence table), PLATFORM_INGEST, SVC_SILVER_ERP.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Setup 1: snapshot table -------------------------------------------------------
use role sysadmin;
create or replace table spike_lab.evidence.s9c_storage (
  run_id varchar, cycle int, taken_at timestamp_ntz,
  db varchar, schema_name varchar, table_name varchar, is_transient varchar,
  active_bytes number, time_travel_bytes number, failsafe_bytes number,
  retained_for_clone_bytes number, versions_dropped int, versions_total int
);
grant select, insert on table spike_lab.evidence.s9c_storage to role platform_ingest;
grant select, insert on table spike_lab.evidence.s9c_storage to role svc_silver_erp;
grant select on table spike_lab.evidence.s9c_storage to role silver_steward;

-- Setup 2: raw tables (platform) ------------------------------------------------
use role platform_ingest;
create or replace table raw.erp.s9c_scattered as
  select row_number() over (order by seq4()) as id, randstr(60, random()) as payload
  from table(generator(rowcount => 2000000)) order by id;
create or replace table raw.erp.s9c_clustered as
  select row_number() over (order by seq4()) as id, randstr(60, random()) as payload
  from table(generator(rowcount => 2000000)) order by id;
grant select on table raw.erp.s9c_scattered to role svc_silver_erp;
grant select on table raw.erp.s9c_clustered to role svc_silver_erp;

-- Setup 3: Silver schemas with different retention (unit service role) ---------
use role svc_silver_erp;
drop schema if exists silver.s9c_ret1;
drop schema if exists silver.s9c_ret0;
create schema silver.s9c_ret1 data_retention_time_in_days = 1;
create schema silver.s9c_ret0 data_retention_time_in_days = 0;

-- Cycle 0: initial freeze, baseline snapshot ------------------------------------
use role platform_ingest;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 0, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 0, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Retention actually carried by a clone: the schema's value, or the source's?
insert into spike_lab.evidence.observation
  select $run_id, 'S9c', 'S9c.00.' || table_schema || '.' || table_name,
         'Retention period of a transient clone in ' || table_schema,
         'information_schema.tables.retention_time', null,
         'retention_time=' || retention_time::varchar, 'INFO',
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from silver.information_schema.tables
  where table_schema in ('S9C_RET1', 'S9C_RET0') and table_name like 'RAW__%';

-- Cycle 1 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 1;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 1, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 1, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Cycle 2 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 2;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 2, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 2, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Cycle 3 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 3;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 3, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 3, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Cycle 4 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 4;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 4, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 4, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Cycle 5 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 5;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 5, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 5, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Cycle 6 ---------------------------------------------------------------------
use role platform_ingest;
update raw.erp.s9c_scattered set payload = randstr(60, random()) where mod(id, 10) = 6;
update raw.erp.s9c_clustered set payload = randstr(60, random()) where id > 1900000;
select system$wait(2);
set wm = (select dateadd(second, -1, sysdate()));
insert into spike_lab.evidence.s9c_storage
  select $run_id, 6, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from raw.information_schema.table_storage_metrics
  where table_schema = 'ERP' and table_name like 'S9C_%'
  group by table_catalog, table_schema, table_name;
use role svc_silver_erp;
create or replace transient table silver.s9c_ret1.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret1.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__scattered
  clone raw.erp.s9c_scattered at (timestamp => $wm);
create or replace transient table silver.s9c_ret0.raw__clustered
  clone raw.erp.s9c_clustered at (timestamp => $wm);
insert into spike_lab.evidence.s9c_storage
  select $run_id, 6, sysdate(), table_catalog, table_schema, table_name, any_value(is_transient),
         sum(active_bytes), sum(time_travel_bytes), sum(failsafe_bytes), sum(retained_for_clone_bytes),
         count_if(table_dropped is not null), count(*)
  from silver.information_schema.table_storage_metrics
  where table_schema in ('S9C_RET1','S9C_RET0')
  group by table_catalog, table_schema, table_name;

-- Summary rows into the observation table -------------------------------------
use role sysadmin;
insert into spike_lab.evidence.observation
  select $run_id, 'S9c', 'S9c.1' || lpad(cycle::varchar, 2, '0') || '.' || schema_name || '.' || table_name,
         'Storage after cycle ' || cycle || ': ' || db || '.' || schema_name || '.' || table_name,
         'information_schema.table_storage_metrics', null,
         'active_mb=' || round(active_bytes / 1048576, 1) || '; time_travel_mb=' || round(time_travel_bytes / 1048576, 1)
           || '; retained_for_clone_mb=' || round(retained_for_clone_bytes / 1048576, 1)
           || '; failsafe_mb=' || round(failsafe_bytes / 1048576, 1)
           || '; versions=' || versions_total || ' (dropped ' || versions_dropped || ')',
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct(*)
  from spike_lab.evidence.s9c_storage
  where run_id = $run_id;

-- Evidence: the trend, one row per cycle and table ------------------------------
select cycle, db || '.' || schema_name || '.' || table_name as table_name, is_transient,
       round(active_bytes / 1048576, 1)             as active_mb,
       round(time_travel_bytes / 1048576, 1)        as time_travel_mb,
       round(retained_for_clone_bytes / 1048576, 1) as retained_for_clone_mb,
       round(failsafe_bytes / 1048576, 1)           as failsafe_mb,
       versions_dropped, versions_total
from spike_lab.evidence.s9c_storage
where run_id = $run_id
order by table_name, cycle;
