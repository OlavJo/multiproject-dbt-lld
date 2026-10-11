-- =============================================================================
-- Phase 2 / Step 09: prerequisites of spike S4 (CDC history and snapshots)
--
-- A third Source Entity unit, silver.s4, run by the ERP unit's service role (target prod_s4):
--   raw.s4.orders_cdc   a CDC feed with the source ordering column and the source commit time
--   raw.s4.customers    a full-load table (no change capture): a snapshot is the only way to
--                       keep its history
--   silver.s4           the unit's published schema
-- and the run-control rows for the unit. Landing records are written with
-- raw.control.land_batch('S4', true) (the procedure only records the batch).
--
-- Requires setup/06 to 08. Run as: PLATFORM_INGEST, SVC_SILVER_ERP, SILVER_STEWARD
-- (the script switches roles). Idempotent; raw tables are recreated.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;

use role platform_ingest;
create schema if not exists raw.s4;
create or replace table raw.s4.orders_cdc (
  order_id    int,
  status      varchar,
  amount      number(18, 2),
  _op         varchar,                       -- I, U or D
  _seq        number,                        -- source ordering column
  _commit_ts  timestamp_ntz,                 -- source commit time
  _loaded_at  timestamp_ntz default sysdate()
);
create or replace table raw.s4.customers (
  customer_id int,
  name        varchar,
  tier        varchar,
  _loaded_at  timestamp_ntz default sysdate()
);
grant usage on schema raw.s4 to role svc_silver_erp;
grant select on table raw.s4.orders_cdc to role svc_silver_erp;
grant select on table raw.s4.customers  to role svc_silver_erp;

use role svc_silver_erp;
create schema if not exists silver.s4 with managed access;
grant usage on schema silver.s4 to database role silver.reader;

use role silver_steward;
merge into analytics_ops.control.units u
  using (select * from (values
      ('raw.s4',    'RAW', 0,  null,       null),
      ('silver.s4', 'T0',  30, 'unit_s4',  'prod_s4'))
    as v(unit, tier, max_runtime_minutes, selector, dbt_target)) s
  on u.unit = s.unit
  when matched then update set selector = s.selector, dbt_target = s.dbt_target
  when not matched then insert (unit, tier, max_runtime_minutes, selector, dbt_target)
    values (s.unit, s.tier, s.max_runtime_minutes, s.selector, s.dbt_target);
insert into analytics_ops.control.unit_lease (unit)
  select u.unit from analytics_ops.control.units u
  where not exists (select 1 from analytics_ops.control.unit_lease l where l.unit = u.unit);
merge into analytics_ops.control.unit_dependencies d
  using (select * from (values ('silver.s4', 'raw.s4', 24)) as v(unit, upstream_unit, max_age_hours)) s
  on d.unit = s.unit and d.upstream_unit = s.upstream_unit
  when matched then update set max_age_hours = s.max_age_hours
  when not matched then insert (unit, upstream_unit, max_age_hours) values (s.unit, s.upstream_unit, s.max_age_hours);

-- The project was deployed with the S4 models: the gate sees a DEPLOYED event for the unit
insert into analytics_ops.control.publish_log (unit, event_type, detail)
  select 'silver.s4', 'DEPLOYED', object_construct('by', 'setup/09');

use role platform_ingest;   -- raw.s4 belongs to the platform; the steward has no privilege on it
show tables in schema raw.s4;
