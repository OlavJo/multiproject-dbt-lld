-- =============================================================================
-- Spike S9 (visibility half): frozen inputs, classification carry-over, masking
-- See README.md in this folder for the question, method and result.
-- Requires setup/05_governance.sql.
--
--   Part A  raw source with two classified columns          (PLATFORM_INGEST)
--             email: tag PII       (explicit carry-over, SLD 6.3)
--             phone: tag PII_AUTO  (PROPAGATE = ON_DATA_MOVEMENT)
--   Part B  freeze: transient clone AT the watermark, and the
--           session-timezone question for UTC watermarks     (SVC_SILVER_ERP)
--   Part C  build and publish one unit: base view, tagged and
--           untagged materialisations, grant-swap-revoke      (SVC_SILVER_ERP)
--   Part D  tags on published columns                        (SVC_SILVER_ERP)
--   Part E  what the consumer sees                           (ANALYST_TIER1)
--
-- SYSTEM$GET_TAG results are recorded inline, never through RESULT_SCAN
-- (spike log: SYSTEM$ results may carry a too-short declared type).
-- Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- =============================================================================
-- Part A: raw source (simulated platform team)
-- =============================================================================
use role platform_ingest;
create schema if not exists raw.erp;

create or replace table raw.erp.customers (
  id         int,
  email      varchar,
  phone      varchar,
  name       varchar,
  _loaded_at timestamp_ntz
);
insert into raw.erp.customers values
  (1, 'ana@example.com',   '+64 21 000 001', 'Ana',   sysdate()),
  (2, 'ben@example.com',   '+64 21 000 002', 'Ben',   sysdate()),
  (3, 'cat@example.com',   '+64 21 000 003', 'Cat',   sysdate());

alter table raw.erp.customers modify column email set tag governance.policies.pii      = 'email';
alter table raw.erp.customers modify column phone set tag governance.policies.pii_auto = 'phone';

grant usage  on database raw            to role svc_silver_erp;
grant usage  on schema raw.erp          to role svc_silver_erp;
grant select on table raw.erp.customers to role svc_silver_erp;

-- The watermark, as run control stores it: UTC TIMESTAMP_NTZ from SYSDATE().
-- A late row lands after the watermark and must not appear in the frozen input.
select system$wait(2);
set wm = (select sysdate());
select system$wait(2);
insert into raw.erp.customers values (4, 'late@example.com', '+64 21 000 004', 'Late', sysdate());

-- =============================================================================
-- Part B: freeze (SLD 7.2)
-- =============================================================================
use role svc_silver_erp;
drop schema if exists silver.s9;
drop schema if exists silver.s9__build;
create schema silver.s9 with managed access;
grant usage on schema silver.s9 to database role silver.reader;
create or replace schema silver.s9__build clone silver.s9 with managed access;

show parameters like 'TIMEZONE' in session;
insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.00', 'B: session timezone before the freeze',
         'show parameters like ''TIMEZONE'' in session', null,
         "value", 'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

-- B1: clone AT a UTC TIMESTAMP_NTZ watermark under the account's default timezone
call spike_lab.evidence.probe($run_id, 'S9', 'S9.10',
  'B: CLONE AT (TIMESTAMP => UTC NTZ watermark) under the default session timezone',
  'create or replace transient table silver.s9__build.raw__customers clone raw.erp.customers at (timestamp => ''' || $wm || '''::timestamp_ntz)',
  null);
call spike_lab.evidence.probe($run_id, 'S9', 'S9.11',
  'B: rows in that clone (3 expected if the watermark was read as UTC)',
  $$select count(*) from silver.s9__build.raw__customers$$, null);

-- B2: the same with the session in UTC
alter session set timezone = 'UTC';
call spike_lab.evidence.probe($run_id, 'S9', 'S9.12',
  'B: CLONE AT (TIMESTAMP => UTC NTZ watermark) with session TIMEZONE = UTC',
  'create or replace transient table silver.s9__build.raw__customers clone raw.erp.customers at (timestamp => ''' || $wm || '''::timestamp_ntz)',
  '!ERROR:%');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.13', 'KEY B: frozen input holds exactly the rows as of the watermark',
  $$select count(*) from silver.s9__build.raw__customers$$, '3');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.14', 'B: live raw meanwhile holds the late row too',
  $$select count(*) from raw.erp.customers$$, '4');

show tables like 'RAW__CUSTOMERS' in schema silver.s9__build;
insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.15', 'B: the frozen input is a transient table (no Fail-safe storage)',
         'show tables like ''RAW__CUSTOMERS''', 'TRANSIENT',
         "kind", iff("kind" = 'TRANSIENT', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

-- =============================================================================
-- Part C: build and publish (as dbt and the publish procedure would)
-- =============================================================================
-- Base view over the frozen input, bare same-schema reference (S1)
create or replace view silver.s9__build.stg_customers as
  select id, email, phone, name from raw__customers;

-- Materialisation WITH the explicit carry-over post-hook (SLD 6.3)
create or replace table silver.s9__build.ent_customers as
  select id, email, phone, name from silver.s9__build.raw__customers;
alter table silver.s9__build.ent_customers
  modify column email set tag governance.policies.pii = 'email';

-- Materialisation WITHOUT the post-hook: what happens if carry-over is forgotten
create or replace table silver.s9__build.ent_customers_untagged as
  select id, email, phone, name from silver.s9__build.raw__customers;

-- Data movement can propagate tags asynchronously; give it a moment
select system$wait(10);

grant select on view  silver.s9__build.stg_customers          to database role silver.reader;
grant select on table silver.s9__build.ent_customers          to database role silver.reader;
grant select on table silver.s9__build.ent_customers_untagged to database role silver.reader;

grant  usage on schema silver.s9__build to database role silver.reader;
alter schema silver.s9__build swap with silver.s9;
revoke usage on schema silver.s9__build from database role silver.reader;

-- =============================================================================
-- Part D: classification tags on published columns
-- =============================================================================
insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.20', 'D: frozen input clone carries the raw PII tag on email',
         'system$get_tag(pii, silver.s9.raw__customers.email)', 'email', v, iff(v = 'email', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select nvl(system$get_tag('governance.policies.pii', 'silver.s9.raw__customers.email', 'column')::varchar, '<NULL>') as v);

insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.21', 'D: frozen input clone carries the raw PII_AUTO tag on phone',
         'system$get_tag(pii_auto, silver.s9.raw__customers.phone)', 'phone', v, iff(v = 'phone', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select nvl(system$get_tag('governance.policies.pii_auto', 'silver.s9.raw__customers.phone', 'column')::varchar, '<NULL>') as v);

insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.22', 'D: CTAS does NOT carry the plain PII tag (SLD 6.3 premise)',
         'system$get_tag(pii, silver.s9.ent_customers_untagged.email)', '<NULL>', v, iff(v = '<NULL>', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select nvl(system$get_tag('governance.policies.pii', 'silver.s9.ent_customers_untagged.email', 'column')::varchar, '<NULL>') as v);

insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.23', 'D: post-hook carries the PII tag onto the materialised email column',
         'system$get_tag(pii, silver.s9.ent_customers.email)', 'email', v, iff(v = 'email', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select nvl(system$get_tag('governance.policies.pii', 'silver.s9.ent_customers.email', 'column')::varchar, '<NULL>') as v);

insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.24', 'KEY D: PII_AUTO propagates onto the CTAS phone column without a post-hook',
         'system$get_tag(pii_auto, silver.s9.ent_customers_untagged.phone)', 'phone', v, iff(v = 'phone', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from (select nvl(system$get_tag('governance.policies.pii_auto', 'silver.s9.ent_customers_untagged.phone', 'column')::varchar, '<NULL>') as v);

-- Grants on the frozen input after clone and swap: ownership only
show grants on table silver.s9.raw__customers;
insert into spike_lab.evidence.observation
  select $run_id, 'S9', 'S9.25', 'D: the frozen input has no grants except ownership',
         'show grants on table silver.s9.raw__customers', 'OWNERSHIP -> ROLE SVC_SILVER_ERP',
         listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
           within group (order by "privilege"),
         iff(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
               = 'OWNERSHIP -> ROLE SVC_SILVER_ERP', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

-- Control: the Silver service role sees clear values through the base view
call spike_lab.evidence.probe($run_id, 'S9', 'S9.26', 'D control: Silver service role reads email unmasked via the base view',
  $$select email from silver.s9.stg_customers where id = 1$$, 'ana@example.com');

-- =============================================================================
-- Part E: what the consumer sees
-- =============================================================================
use role analyst_tier1;

call spike_lab.evidence.probe($run_id, 'S9', 'S9.30', 'E: consumer cannot read the frozen input',
  $$select count(*) from silver.s9.raw__customers$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.31', 'E: consumer cannot read raw',
  $$select count(*) from raw.erp.customers$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.32', 'E: consumer reads the base view (rows as of the watermark)',
  $$select count(*) from silver.s9.stg_customers$$, '3');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.33', 'KEY E: email masked through the base view (policy carried by clone)',
  $$select email from silver.s9.stg_customers where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.34', 'E: phone masked through the base view',
  $$select phone from silver.s9.stg_customers where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.35', 'E: email masked in the materialised table with the post-hook',
  $$select email from silver.s9.ent_customers where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.36', 'E: phone masked in the materialised table (propagation)',
  $$select phone from silver.s9.ent_customers where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.37', 'HAZARD E: email in clear in the materialised table WITHOUT the post-hook (SLD 6.3 premise)',
  $$select email from silver.s9.ent_customers_untagged where id = 1$$, 'ana@example.com');
call spike_lab.evidence.probe($run_id, 'S9', 'S9.38', 'KEY E: phone masked WITHOUT any post-hook, by tag propagation',
  $$select phone from silver.s9.ent_customers_untagged where id = 1$$, '***MASKED***');

-- Evidence ---------------------------------------------------------------------
use role svc_silver_erp;
alter session unset timezone;
select case_id, outcome, description, observed, expected, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Export as evidence/S9_<yyyymmdd>.csv
