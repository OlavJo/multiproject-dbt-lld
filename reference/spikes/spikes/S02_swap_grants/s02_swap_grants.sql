-- =============================================================================
-- Spike S2: SWAP WITH and grants
-- See README.md in this folder for the question, method and result.
--
-- Roles:
--   SVC_SILVER_ERP   owns the unit's schema pair and runs the publish cycle
--   ANALYST_TIER1    consumer; holds database role SILVER.READER only
--
-- Grants follow SLD 10.7 rule 5: schema USAGE plus per-object SELECT on
-- published objects, granted to the database role; internal objects never
-- granted; no future grants.
--
-- Variants:
--   A  standard schema, plain swap (does schema USAGE stay with the name?)
--   B  standard schema, explicit grant sequence around the swap
--   C  managed-access schema, plain swap
--   D  managed-access schema, ENABLE MANAGED ACCESS on build, grant sequence
--      (added after run 1)
--   E  managed-access clone in one statement (added after run 2; self-contained)
-- Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- =============================================================================
-- Variant A: standard schema, plain swap
-- =============================================================================
use role svc_silver_erp;
drop schema if exists silver.s2;
drop schema if exists silver.s2__build;

create schema silver.s2;
create table silver.s2.pub_t  (marker varchar) as select 'V1';  -- published, rebuilt each cycle
create table silver.s2.keep_t (marker varchar) as select 'V1';  -- published, NOT rebuilt (travels by clone)
create table silver.s2.int_t  (marker varchar) as select 'V1';  -- internal, never granted
grant usage  on schema silver.s2        to database role silver.reader;
grant select on table  silver.s2.pub_t  to database role silver.reader;
grant select on table  silver.s2.keep_t to database role silver.reader;

-- Baseline (consumer)
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.01', 'A baseline: consumer reads published table',
  $$select marker from silver.s2.pub_t$$, 'V1');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.02', 'A baseline: consumer cannot read internal table',
  $$select marker from silver.s2.int_t$$, 'ERROR:%');

-- Step 2: clone last good state
use role svc_silver_erp;
create or replace schema silver.s2__build clone silver.s2;

show grants on schema silver.s2__build;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.03', 'A after clone: schema-level grants on the build schema',
         'show grants on schema silver.s2__build', null,
         nvl(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
               within group (order by "privilege", "grantee_name"), '<none>'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

show grants on table silver.s2__build.keep_t;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.04', 'A after clone: object grants copied onto cloned child objects',
         'show grants on table silver.s2__build.keep_t', '%SELECT -> DATABASE_ROLE%READER%',
         nvl(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
               within group (order by "privilege", "grantee_name"), '<none>'),
         iff(nvl(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; '), '') ilike '%SELECT -> DATABASE_ROLE%READER%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.05', 'A after clone: consumer has no access to the build schema',
  $$select marker from silver.s2__build.keep_t$$, 'ERROR:%');

-- Step 4: build (dbt replaces the table, then applies its grants config)
use role svc_silver_erp;
create or replace table silver.s2__build.pub_t (marker varchar) as select 'V2';
grant select on table silver.s2__build.pub_t to database role silver.reader;
create or replace table silver.s2__build.int_t (marker varchar) as select 'V2';

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.06', 'A before swap: consumer still cannot read the built table in the build schema',
  $$select marker from silver.s2__build.pub_t$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.07', 'A before swap: consumer reads the last good version',
  $$select marker from silver.s2.pub_t$$, 'V1');

-- Step 5: swap
use role svc_silver_erp;
alter schema silver.s2__build swap with silver.s2;

show grants on schema silver.s2;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.08', 'A after swap: schema-level grants on the PUBLISHED name',
         'show grants on schema silver.s2', null,
         nvl(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
               within group (order by "privilege", "grantee_name"), '<none>'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

show grants on schema silver.s2__build;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.09', 'A after swap: schema-level grants on the BUILD name',
         'show grants on schema silver.s2__build', null,
         nvl(listagg("privilege" || ' -> ' || "granted_to" || ' ' || "grantee_name", '; ')
               within group (order by "privilege", "grantee_name"), '<none>'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.10',
  'KEY A: after a plain swap, consumer reads the NEW published table (USAGE stayed with the name)',
  $$select marker from silver.s2.pub_t$$, 'V2');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.11',
  'A after swap: consumer reads the untouched table that travelled by clone and swap',
  $$select marker from silver.s2.keep_t$$, 'V1');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.12',
  'A after swap: consumer cannot read the previous version now in the build schema',
  $$select marker from silver.s2__build.pub_t$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.13',
  'A after swap: consumer still cannot read the internal table',
  $$select marker from silver.s2.int_t$$, 'ERROR:%');

-- =============================================================================
-- Variant B: explicit grant sequence (SLD 10.7 rule 5, fallback)
--   grant USAGE on build -> swap -> revoke USAGE from the new build schema
-- Run from a clean baseline so its result does not depend on variant A.
-- =============================================================================
use role svc_silver_erp;
drop schema if exists silver.s2;
drop schema if exists silver.s2__build;
create schema silver.s2;
create table silver.s2.pub_t (marker varchar) as select 'V1';
create table silver.s2.int_t (marker varchar) as select 'V1';
grant usage  on schema silver.s2       to database role silver.reader;
grant select on table  silver.s2.pub_t to database role silver.reader;

create or replace schema silver.s2__build clone silver.s2;
create or replace table silver.s2__build.pub_t (marker varchar) as select 'V2';
grant select on table silver.s2__build.pub_t to database role silver.reader;

grant  usage on schema silver.s2__build to database role silver.reader;
alter schema silver.s2__build swap with silver.s2;
revoke usage on schema silver.s2__build from database role silver.reader;

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.20', 'B: consumer reads NEW after grant-swap-revoke',
  $$select marker from silver.s2.pub_t$$, 'V2');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.21', 'B: consumer has no access to the build schema after revoke',
  $$select marker from silver.s2__build.pub_t$$, 'ERROR:%');

-- =============================================================================
-- Variant C: managed-access schemas (SLD 16 open item: grant behaviour in
-- managed-access schemas). Plain swap, as in A.
-- =============================================================================
use role svc_silver_erp;
drop schema if exists silver.s2m;
drop schema if exists silver.s2m__build;
create schema silver.s2m with managed access;
create table silver.s2m.pub_t (marker varchar) as select 'V1';
grant usage  on schema silver.s2m       to database role silver.reader;
grant select on table  silver.s2m.pub_t to database role silver.reader;

show schemas like 'S2M' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.29', 'C control: the source schema is managed access',
         'show schemas like ''S2M''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

create or replace schema silver.s2m__build clone silver.s2m;

show schemas like 'S2M__BUILD' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.30', 'C: clone of a managed-access schema is itself managed access',
         'show schemas like ''S2M__BUILD''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

create or replace table silver.s2m__build.pub_t (marker varchar) as select 'V2';
call spike_lab.evidence.probe($run_id, 'S2', 'S2.31',
  'C: schema-owning service role can grant SELECT in a managed-access build schema (dbt grants step)',
  $$grant select on table silver.s2m__build.pub_t to database role silver.reader$$, '!ERROR:%');

alter schema silver.s2m__build swap with silver.s2m;

show schemas like 'S2M' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.34', 'C after swap: the PUBLISHED schema is still managed access',
         'show schemas like ''S2M''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.32',
  'KEY C: managed access, after a plain swap, consumer reads NEW',
  $$select marker from silver.s2m.pub_t$$, 'V2');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.33',
  'C: consumer has no access to the managed-access build schema',
  $$select marker from silver.s2m__build.pub_t$$, 'ERROR:%');

-- =============================================================================
-- Variant D (added after run 1): managed access kept explicitly, plus the
-- grant sequence that run 1 showed to be necessary (variant B):
--   clone -> ENABLE MANAGED ACCESS on build -> build -> grant USAGE on build
--   -> swap -> revoke USAGE from the new build schema
-- =============================================================================
use role svc_silver_erp;
drop schema if exists silver.s2d;
drop schema if exists silver.s2d__build;
create schema silver.s2d with managed access;
create table silver.s2d.pub_t (marker varchar) as select 'V1';
create table silver.s2d.int_t (marker varchar) as select 'V1';
grant usage  on schema silver.s2d       to database role silver.reader;
grant select on table  silver.s2d.pub_t to database role silver.reader;

create or replace schema silver.s2d__build clone silver.s2d;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.40',
  'D: unit service role can enable managed access on its cloned build schema',
  $$alter schema silver.s2d__build enable managed access$$, '!ERROR:%');
show schemas like 'S2D__BUILD' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.41', 'D: build schema is managed access after ENABLE',
         'show schemas like ''S2D__BUILD''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

create or replace table silver.s2d__build.pub_t (marker varchar) as select 'V2';
grant select on table silver.s2d__build.pub_t to database role silver.reader;
create or replace table silver.s2d__build.int_t (marker varchar) as select 'V2';

grant  usage on schema silver.s2d__build to database role silver.reader;
alter schema silver.s2d__build swap with silver.s2d;
revoke usage on schema silver.s2d__build from database role silver.reader;

show schemas like 'S2D' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.42', 'D after swap: the PUBLISHED schema is managed access',
         'show schemas like ''S2D''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.43', 'KEY D: consumer reads NEW after the full sequence',
  $$select marker from silver.s2d.pub_t$$, 'V2');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.44', 'D: consumer has no access to the build schema',
  $$select marker from silver.s2d__build.pub_t$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.45', 'D: consumer cannot read the internal table',
  $$select marker from silver.s2d.int_t$$, 'ERROR:%');

-- =============================================================================
-- Variant E (added after run 2): create the build schema as a managed-access
-- clone in one statement, without MANAGE GRANTS. Run 2 showed that a plain
-- clone drops managed access (S2.30) and that ENABLE MANAGED ACCESS needs
-- MANAGE GRANTS on the account (S2.40).
-- Self-contained: can be run on its own from this header.
-- =============================================================================
use role svc_silver_erp;
use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

drop schema if exists silver.s2e;
drop schema if exists silver.s2e__build;
drop schema if exists silver.s2e__build_alt;
create schema silver.s2e with managed access;
create table silver.s2e.pub_t (marker varchar) as select 'V1';
create table silver.s2e.int_t (marker varchar) as select 'V1';
grant usage  on schema silver.s2e       to database role silver.reader;
grant select on table  silver.s2e.pub_t to database role silver.reader;

-- Two candidate clause orders; record which Snowflake accepts.
call spike_lab.evidence.probe($run_id, 'S2', 'S2.50',
  'E: CREATE SCHEMA ... CLONE ... WITH MANAGED ACCESS accepted by the unit service role',
  $$create or replace schema silver.s2e__build clone silver.s2e with managed access$$,
  '!ERROR:%');
show schemas like 'S2E__BUILD' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.51', 'E: build schema created by S2.50 is managed access',
         'show schemas like ''S2E__BUILD''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

call spike_lab.evidence.probe($run_id, 'S2', 'S2.52',
  'E: CREATE SCHEMA ... WITH MANAGED ACCESS CLONE ... accepted (alternative clause order)',
  $$create or replace schema silver.s2e__build_alt with managed access clone silver.s2e$$,
  '!ERROR:%');
show schemas like 'S2E__BUILD_ALT' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.53', 'E: build schema created by S2.52 is managed access',
         'show schemas like ''S2E__BUILD_ALT''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

-- Publication cycle on the S2.50 build schema, with the grant sequence
create or replace table silver.s2e__build.pub_t (marker varchar) as select 'V2';
grant select on table silver.s2e__build.pub_t to database role silver.reader;
create or replace table silver.s2e__build.int_t (marker varchar) as select 'V2';

grant  usage on schema silver.s2e__build to database role silver.reader;
alter schema silver.s2e__build swap with silver.s2e;
revoke usage on schema silver.s2e__build from database role silver.reader;

show schemas like 'S2E' in database silver;
insert into spike_lab.evidence.observation
  select $run_id, 'S2', 'S2.54', 'KEY E: after swap, the PUBLISHED schema is managed access',
         'show schemas like ''S2E''', '%MANAGED ACCESS%',
         nvl(nullif("options", ''), '<none>'),
         iff(nvl("options", '') ilike '%MANAGED ACCESS%', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S2', 'S2.55', 'E: consumer reads NEW',
  $$select marker from silver.s2e.pub_t$$, 'V2');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.56', 'E: consumer has no access to the build schema',
  $$select marker from silver.s2e__build.pub_t$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S2', 'S2.57', 'E: consumer cannot read the internal table',
  $$select marker from silver.s2e.int_t$$, 'ERROR:%');

use role svc_silver_erp;
select case_id, outcome, description, observed, expected, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Variant E alone: export as evidence/S2E_<yyyymmdd>.csv

-- Evidence ---------------------------------------------------------------------
use role svc_silver_erp;
select case_id, outcome, description, observed, expected, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Export this result as evidence/S2_<yyyymmdd>.csv
