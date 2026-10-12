-- =============================================================================
-- Prototype / Increment 2 / Step 10: landing batches and the landing-complete record
--
-- Stands in for the platform team (component 10; SLD 4.1, EX-1):
--   raw.control.landing_complete   one row per landed batch, written LAST
--   raw.control.land_batch(source, empty)
--                                  lands one batch for ERP, CRM or HR, then writes the
--                                  record; empty = true simulates a batch with no new rows in
--                                  ANY table of the source (a quiet source): the record is still
--                                  written, so the source stays fresh
-- Completeness is per source and batch, never per table (SLD 4.1): one record closes the batch
-- once every table has committed, whether or not a given table received new rows. The freeze
-- then clones every table of the source at that one watermark (SLD 7.2).
-- The steward reads the landing-complete table (for the analytics view in i2_20).
--
-- Run as: PLATFORM_INGEST. Requires: i1_20. Idempotent: the table is created if
-- missing and never truncated, so landing history survives a rerun.
-- =============================================================================

use role platform_ingest;
use secondary roles none;
use warehouse lld_wh;

create schema if not exists raw.control with managed access;

create table if not exists raw.control.landing_complete (
  source_system varchar,          -- 'ERP', 'CRM', 'HR'
  batch_id      varchar,
  completed_at  timestamp_ntz,    -- UTC; the watermark a unit may freeze at
  detail        variant
);

create or replace procedure raw.control.land_batch(p_source varchar, p_empty boolean)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  v_src   varchar;
  v_batch varchar default uuid_string();
  v_n     integer default 0;
begin
  v_src := upper(p_source);
  if (v_src not in ('ERP', 'CRM', 'HR')) then
    return 'REFUSED:unknown_source';
  end if;
  select count(*) into :v_n from raw.control.landing_complete where source_system = :v_src;
  if (not p_empty) then
    if (v_src = 'ERP') then
      -- two new accounts, two new orders, and a new version of the oldest order (CDC)
      insert into raw.erp.accounts (account_id, email, account_name)
        select b.m + seq4() + 1, 'user' || (b.m + seq4() + 1) || '@example.com', 'Account ' || (b.m + seq4() + 1)
        from (select coalesce(max(account_id), 0) as m from raw.erp.accounts) b, table(generator(rowcount => 2));
      insert into raw.erp.orders (order_id, account_id, status, amount, _seq)
        select b.m + seq4() + 1, 1, 'NEW', 10 * (seq4() + 1), b.s + seq4() + 1
        from (select coalesce(max(order_id), 0) as m, coalesce(max(_seq), 0) as s from raw.erp.orders) b,
             table(generator(rowcount => 2));
      insert into raw.erp.orders (order_id, account_id, status, amount, _seq)
        select o.order_id, o.account_id, iff(:v_n % 2 = 0, 'SHIPPED', 'RETURNED'), o.amount,
               (select max(_seq) + 1 from raw.erp.orders)
        from raw.erp.orders o
        where o.order_id = (select min(order_id) from raw.erp.orders)
        qualify row_number() over (order by o._seq desc) = 1;
    elseif (v_src = 'CRM') then
      insert into raw.crm.contacts (contact_id, full_name, segment)
        select b.m + seq4() + 1, 'Contact ' || (b.m + seq4() + 1), iff(seq4() % 2 = 0, 'SMB', 'ENTERPRISE')
        from (select coalesce(max(contact_id), 0) as m from raw.crm.contacts) b, table(generator(rowcount => 2));
    else
      insert into raw.hr.employees (employee_id, full_name, salary)
        select b.m + seq4() + 1, 'Employee ' || (b.m + seq4() + 1), 90000 + 1000 * seq4()
        from (select coalesce(max(employee_id), 0) as m from raw.hr.employees) b, table(generator(rowcount => 1));
    end if;
  end if;
  -- The record is written last: a batch is complete when its record exists (SLD 4.1)
  insert into raw.control.landing_complete
    select :v_src, :v_batch, sysdate(), object_construct('empty', :p_empty, 'batch_no', :v_n + 1);
  return 'LANDED:' || v_src || ':' || v_batch;
end;
$$;

-- The steward's analytics view reads the record (SLD 4.1: analytics may read it)
grant usage on schema raw.control                  to role silver_steward;
grant select on table raw.control.landing_complete to role silver_steward;
grant usage on database raw                        to role silver_steward;

show tables in schema raw.control;
