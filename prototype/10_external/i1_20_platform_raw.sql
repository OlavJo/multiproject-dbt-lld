-- =============================================================================
-- Prototype / Increment 1 / Step 20: simulated platform landing (raw)
--
-- Stands in for the platform team (component 10). Three sources, one sensitive:
--   raw.erp  accounts, orders     raw.crm  contacts     raw.hr  employees
--
-- Each source has a raw reader DATABASE ROLE (raw.reader_<source>) owned by the
-- platform: SELECT on the source's tables, present and future. Onboarding a Silver
-- unit ends with the platform granting that role to the unit's service role
-- (LLD 01, 7.1.1), so raw access stays a platform decision.
--
-- Schemas are managed access, so the platform (schema owner) can define the future
-- grants without MANAGE GRANTS. Data is minimal here; Increment 2 adds batches and
-- the landing-complete record.
--
-- Run as: PLATFORM_INGEST. Requires: i1_10. Idempotent (tables are recreated).
-- =============================================================================

use role platform_ingest;
use secondary roles none;
use warehouse lld_wh;

create schema if not exists raw.erp with managed access;
create schema if not exists raw.crm with managed access;
create schema if not exists raw.hr  with managed access;

create or replace table raw.erp.accounts (
  account_id int, email varchar, account_name varchar, _loaded_at timestamp_ntz default sysdate());
create or replace table raw.erp.orders (
  order_id int, account_id int, status varchar, amount number(18, 2), _seq number,
  _loaded_at timestamp_ntz default sysdate());
create or replace table raw.crm.contacts (
  contact_id int, full_name varchar, segment varchar, _loaded_at timestamp_ntz default sysdate());
create or replace table raw.hr.employees (
  employee_id int, full_name varchar, salary number(12, 2), _loaded_at timestamp_ntz default sysdate());

insert into raw.erp.accounts (account_id, email, account_name) values (1, 'user1@example.com', 'Account 1');
insert into raw.erp.orders (order_id, account_id, status, amount, _seq) values (1, 1, 'NEW', 10, 1);
insert into raw.crm.contacts (contact_id, full_name, segment) values (1, 'Contact 1', 'SMB');
insert into raw.hr.employees (employee_id, full_name, salary) values (1, 'Employee 1', 100000);

-- Raw reader database roles, one per source --------------------------------------------
declare
  c_src cursor for select value::varchar as s from table(flatten(input => parse_json('["erp","crm","hr"]')));
begin
  for rec in c_src do
    execute immediate 'create database role if not exists raw.reader_' || rec.s;
    execute immediate 'grant usage on schema raw.' || rec.s || ' to database role raw.reader_' || rec.s;
    execute immediate 'grant select on all tables in schema raw.' || rec.s || ' to database role raw.reader_' || rec.s;
    execute immediate 'grant select on future tables in schema raw.' || rec.s || ' to database role raw.reader_' || rec.s;
  end for;
  return 'raw reader roles done';
end;

show database roles in database raw;
