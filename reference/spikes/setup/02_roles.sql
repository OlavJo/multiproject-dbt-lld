-- =============================================================================
-- Phase 0 / Step 02: Roles, databases and ownership
--
-- A first cut of the role catalogue (SLD 16, "Role catalogue"), limited to what
-- Phase 1 needs. Later phases add Core, Tier 1 and Tier 2 roles.
--
--   PLATFORM_INGEST   simulated platform team; owns RAW and the landing-complete table
--   SILVER_STEWARD    steward team; owns the SILVER and ANALYTICS_OPS databases,
--                     the SILVER.READER database role, and the Git repository object
--   SVC_SILVER_ERP    per-unit service role; owns the ERP unit's schema pair
--                     (silver.erp, silver.erp__build) and the S1/S2 test schemas
--   ANALYST_TIER1     a Tier 1 consumer; reads Silver only via SILVER.READER
--
-- Design choice to review in the LLD: the roles are flat (each granted to
-- SYSADMIN for administration). The steward does NOT inherit the service roles,
-- so steward-role and service-role privileges can be tested separately.
--
-- Run as: USERADMIN (create roles), SECURITYADMIN (grant roles),
--         SYSADMIN (databases), then the owning roles themselves.
-- Idempotent.
-- =============================================================================

use secondary roles none;
set me = (select current_user());

-- Roles ------------------------------------------------------------------------
use role useradmin;
create role if not exists platform_ingest comment = 'Spike: simulated platform ingestion team';
create role if not exists silver_steward  comment = 'Spike: Silver steward team';
create role if not exists svc_silver_erp  comment = 'Spike: service role for the Silver ERP unit';
create role if not exists analyst_tier1   comment = 'Spike: Tier 1 consumer of Silver';

use role securityadmin;
grant role platform_ingest to role sysadmin;
grant role silver_steward  to role sysadmin;
grant role svc_silver_erp  to role sysadmin;
grant role analyst_tier1   to role sysadmin;

-- The spike user can assume each role (one at a time; secondary roles off)
grant role platform_ingest to user identifier($me);
grant role silver_steward  to user identifier($me);
grant role svc_silver_erp  to user identifier($me);
grant role analyst_tier1   to user identifier($me);

-- Warehouse and evidence access for every spike role ---------------------------
use role sysadmin;
grant usage on warehouse spike_wh to role platform_ingest;
grant usage on warehouse spike_wh to role silver_steward;
grant usage on warehouse spike_wh to role svc_silver_erp;
grant usage on warehouse spike_wh to role analyst_tier1;

grant usage on database spike_lab          to role platform_ingest;
grant usage on database spike_lab          to role silver_steward;
grant usage on database spike_lab          to role svc_silver_erp;
grant usage on database spike_lab          to role analyst_tier1;
grant usage on schema spike_lab.evidence   to role platform_ingest;
grant usage on schema spike_lab.evidence   to role silver_steward;
grant usage on schema spike_lab.evidence   to role svc_silver_erp;
grant usage on schema spike_lab.evidence   to role analyst_tier1;
grant select, insert on table spike_lab.evidence.observation to role platform_ingest;
grant select, insert on table spike_lab.evidence.observation to role silver_steward;
grant select, insert on table spike_lab.evidence.observation to role svc_silver_erp;
grant select, insert on table spike_lab.evidence.observation to role analyst_tier1;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role platform_ingest;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role silver_steward;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role svc_silver_erp;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role analyst_tier1;

-- Databases --------------------------------------------------------------------
create database if not exists raw           comment = 'Spike: simulated Bronze landing (platform-owned)';
create database if not exists silver        comment = 'Spike: Silver Layer';
create database if not exists analytics_ops comment = 'Spike: run control';

grant ownership on database raw           to role platform_ingest copy current grants;
grant ownership on database silver        to role silver_steward  copy current grants;
grant ownership on database analytics_ops to role silver_steward  copy current grants;

-- Steward-owned schemas in SPIKE_LAB for Git and the hello dbt project
create schema if not exists spike_lab.git;
create schema if not exists spike_lab.hello;
grant ownership on schema spike_lab.git   to role silver_steward copy current grants;
grant ownership on schema spike_lab.hello to role silver_steward copy current grants;

-- Steward: Silver structure and the reader database role -----------------------
use role silver_steward;

-- Units create their own schema pairs (SLD 10.4: the unit's service role owns both)
grant usage, create schema on database silver to role svc_silver_erp;

-- Consumers read Silver through one database role (SLD 16 open item)
create database role if not exists silver.reader;
grant usage on database silver to database role silver.reader;
grant database role silver.reader to role analyst_tier1;

-- Evidence ---------------------------------------------------------------------
use role sysadmin;
show grants to role svc_silver_erp;
show grants to role analyst_tier1;
show grants to database role silver.reader;
