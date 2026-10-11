-- =============================================================================
-- Phase 2 / Step 06: prerequisites of the shared Silver dbt project
--
-- Creates what dbt/silver needs before it can be deployed:
--   * a second unit service role (SVC_SILVER_CRM), so two units can run concurrently (S8)
--   * the published schemas silver.erp and silver.crm, owned by the unit roles
--   * simulated platform landing: raw.erp.accounts, raw.erp.orders (CDC-style, with a
--     source ordering column), raw.crm.contacts, the platform-owned landing-complete
--     table raw.control.landing_complete and the procedure raw.control.land_batch
--   * run control additions on the S12 objects: the analytics view
--     v_landing_complete, unit_status with the landing union (SLD 12.6), the units
--     and dependencies for the skeleton
--
-- Requires: setup/00 to 05 (re-run 05 once to create the PII_DEP tag), spike S12
-- (analytics_ops.control tables and lease procedures). Does not recreate them.
-- Run as: USERADMIN, SECURITYADMIN, SYSADMIN, then the owning roles. Idempotent
-- except that raw tables are recreated and landing history restarts.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set me = (select current_user());
set run_id = (select uuid_string());

-- Roles ------------------------------------------------------------------------
use role useradmin;
create role if not exists svc_silver_crm comment = 'Spike: service role for the Silver CRM unit';
use role securityadmin;
grant role svc_silver_crm to role sysadmin;
grant role svc_silver_crm to user identifier($me);
use role sysadmin;
grant usage on warehouse spike_wh to role svc_silver_crm;
grant usage on database spike_lab        to role svc_silver_crm;
grant usage on schema spike_lab.evidence to role svc_silver_crm;
grant select, insert on table spike_lab.evidence.observation to role svc_silver_crm;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role svc_silver_crm;

use role silver_steward;
grant usage, create schema on database silver to role svc_silver_crm;
-- A schema for the dbt project object (SLD 3.1: one object for all Silver units)
create schema if not exists silver.ops;
grant usage on schema silver.ops to role svc_silver_erp;
grant usage on schema silver.ops to role svc_silver_crm;

-- Published schemas, owned by the unit service roles (SLD 10.4) ----------------
use role svc_silver_erp;
create schema if not exists silver.erp with managed access;
grant usage on schema silver.erp to database role silver.reader;
use role svc_silver_crm;
create schema if not exists silver.crm with managed access;
grant usage on schema silver.crm to database role silver.reader;

-- Simulated platform landing (platform-owned) ----------------------------------
use role platform_ingest;
create schema if not exists raw.crm;
create schema if not exists raw.control;

create or replace table raw.erp.accounts (
  account_id   int,
  email        varchar,
  account_name varchar,
  _loaded_at   timestamp_ntz default sysdate()
);
create or replace table raw.erp.orders (
  order_id   int,
  account_id int,
  status     varchar,
  amount     number(18, 2),
  _seq       number,                          -- source ordering column (SLD 4.1)
  _loaded_at timestamp_ntz default sysdate()
);
create or replace table raw.crm.contacts (
  contact_id int,
  full_name  varchar,
  segment    varchar,
  _loaded_at timestamp_ntz default sysdate()
);
-- Classification: PII_DEP propagates through views and on data movement, with the
-- value-aware policy (S9e, S9f). PII_DECL would stop at the base view (S9f).
alter table raw.erp.accounts modify column email set tag governance.policies.pii_dep = 'email';

create table if not exists raw.control.landing_complete (
  source_system varchar,
  batch_id      varchar,
  completed_at  timestamp_ntz,
  detail        variant
);
truncate table raw.control.landing_complete;

-- Land one batch for a source, then write the landing-complete record LAST (SLD 4.1).
-- p_empty = true lands no rows but still writes the record (a quiet source).
create or replace procedure raw.control.land_batch(p_source varchar, p_empty boolean)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  batch_id varchar default uuid_string();
  n_before integer default 0;
begin
  select count(*) into :n_before from raw.control.landing_complete where source_system = upper(:p_source);
  if (not :p_empty) then
    if (upper(:p_source) = 'ERP') then
      insert into raw.erp.accounts (account_id, email, account_name)
        select a.base + seq4() + 1, 'user' || (a.base + seq4() + 1) || '@example.com', 'Account ' || (a.base + seq4() + 1)
        from (select coalesce(max(account_id), 0) as base from raw.erp.accounts) a, table(generator(rowcount => 2));
      -- two new orders for the first account, in this batch
      insert into raw.erp.orders (order_id, account_id, status, amount, _seq)
        select o.base_id + seq4() + 1, 1, 'NEW', 10 * (seq4() + 1), o.base_seq + seq4() + 1
        from (select coalesce(max(order_id), 0) as base_id, coalesce(max(_seq), 0) as base_seq from raw.erp.orders) o,
             table(generator(rowcount => 2));
      -- a new version of the oldest order (CDC: same key, higher ordering value)
      insert into raw.erp.orders (order_id, account_id, status, amount, _seq)
        select order_id, account_id, iff(:n_before % 2 = 0, 'SHIPPED', 'RETURNED'), amount,
               (select max(_seq) from raw.erp.orders) + 1
        from raw.erp.orders
        where order_id = (select min(order_id) from raw.erp.orders) and _seq = (select min(_seq) from raw.erp.orders);
    elseif (upper(:p_source) = 'CRM') then
      insert into raw.crm.contacts (contact_id, full_name, segment)
        select c.base + seq4() + 1, 'Contact ' || (c.base + seq4() + 1), iff(seq4() % 2 = 0, 'SMB', 'ENTERPRISE')
        from (select coalesce(max(contact_id), 0) as base from raw.crm.contacts) c, table(generator(rowcount => 2));
    end if;
  end if;
  insert into raw.control.landing_complete
    select upper(:p_source), :batch_id, sysdate(), object_construct('empty', :p_empty, 'batch_no', :n_before + 1);
  return :batch_id;
end;
$$;

grant usage on database raw to role svc_silver_crm;
grant usage on schema raw.crm     to role svc_silver_crm;
grant usage on schema raw.erp     to role svc_silver_crm;
grant select on table raw.crm.contacts to role svc_silver_crm;
grant select on table raw.erp.accounts to role svc_silver_erp;
grant select on table raw.erp.orders   to role svc_silver_erp;
grant usage on database raw          to role svc_silver_erp;
grant usage on schema raw.erp        to role svc_silver_erp;
-- The landing-complete table is readable by analytics (SLD 4.1)
grant usage on schema raw.control                     to role silver_steward;
grant select on table raw.control.landing_complete    to role silver_steward;
grant usage on database raw                           to role silver_steward;

-- Two initial batches per source
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);
call raw.control.land_batch('ERP', false);

-- Run control additions (steward) -----------------------------------------------
use role silver_steward;
alter table analytics_ops.control.units add column if not exists selector   varchar;
alter table analytics_ops.control.units add column if not exists dbt_target varchar;

create or replace view analytics_ops.control.v_landing_complete as
  select source_system, batch_id, completed_at, detail from raw.control.landing_complete;

merge into analytics_ops.control.units u
  using (select * from (values
      ('raw.erp',    'RAW', 0,  null,       null),
      ('raw.crm',    'RAW', 0,  null,       null),
      ('silver.erp', 'T0',  30, 'unit_erp', 'prod_erp'),
      ('silver.crm', 'T0',  30, 'unit_crm', 'prod_crm'))
    as v(unit, tier, max_runtime_minutes, selector, dbt_target)) s
  on u.unit = s.unit
  when matched then update set selector = s.selector, dbt_target = s.dbt_target
  when not matched then insert (unit, tier, max_runtime_minutes, selector, dbt_target)
    values (s.unit, s.tier, s.max_runtime_minutes, s.selector, s.dbt_target);

insert into analytics_ops.control.unit_lease (unit)
  select u.unit from analytics_ops.control.units u
  where not exists (select 1 from analytics_ops.control.unit_lease l where l.unit = u.unit);

merge into analytics_ops.control.unit_dependencies d
  using (select * from (values ('silver.erp', 'raw.erp', 24), ('silver.crm', 'raw.crm', 24))
         as v(unit, upstream_unit, max_age_hours)) s
  on d.unit = s.unit and d.upstream_unit = s.upstream_unit
  when matched then update set max_age_hours = s.max_age_hours
  when not matched then insert (unit, upstream_unit, max_age_hours) values (s.unit, s.upstream_unit, s.max_age_hours);

-- SLD 12.6: raw units appear in status as PUBLISHED events from the landing records
create or replace view analytics_ops.control.unit_status as
with events as (
  select unit, event_type, event_ts, watermark
  from analytics_ops.control.publish_log
  union all
  select 'raw.' || lower(source_system), 'PUBLISHED', completed_at, completed_at
  from analytics_ops.control.v_landing_complete
)
select
  unit,
  max(iff(event_type = 'PUBLISHED', event_ts, null))                 as published_at,
  max_by(watermark, iff(event_type = 'PUBLISHED', event_ts, null))   as watermark,
  max(iff(event_type = 'DEPLOYED', event_ts, null))                  as deployed_at,
  max_by(event_type, event_ts)                                       as last_event,
  max(event_ts)                                                      as last_event_at
from events
group by unit;

grant usage on database analytics_ops                              to role svc_silver_crm;
grant usage on schema analytics_ops.control                        to role svc_silver_crm;
grant usage on procedure analytics_ops.control.acquire_lease(varchar, varchar) to role svc_silver_crm;
grant usage on procedure analytics_ops.control.release_lease(varchar, varchar) to role svc_silver_crm;
grant select on table analytics_ops.control.unit_lease             to role svc_silver_crm;
grant select on view analytics_ops.control.v_landing_complete      to role svc_silver_erp;
grant select on view analytics_ops.control.v_landing_complete      to role svc_silver_crm;
grant select on view analytics_ops.control.unit_status             to role svc_silver_erp;
grant select on view analytics_ops.control.unit_status             to role svc_silver_crm;

-- Checks -----------------------------------------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.01', 'ERP service role reads the landing-complete view',
  $$select count(*) from analytics_ops.control.v_landing_complete where source_system = 'ERP'$$, '2');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.02', 'ERP service role reads raw accounts clear (policy reveals SVC_SILVER_ERP)',
  $$select email from raw.erp.accounts order by account_id limit 1$$, 'user1@example.com');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.03', 'ERP orders: CDC versions of the oldest order (original plus one per batch)',
  $$select count(*) from raw.erp.orders where order_id = 1$$, '3');
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.04', 'CRM service role reads raw contacts',
  $$select count(*) from raw.crm.contacts$$, '2');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.05', 'CRM service role cannot read ERP raw orders',
  $$select count(*) from raw.erp.orders$$, 'ERROR:%');
use role silver_steward;
call spike_lab.evidence.probe($run_id, 'P2', 'P2.06', 'unit_status lists raw and silver units',
  $$select count(*) from analytics_ops.control.unit_status$$, null);

select case_id, outcome, description, observed, role_name, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by case_id;
