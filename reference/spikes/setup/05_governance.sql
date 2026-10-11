-- =============================================================================
-- Phase 0 / Step 05: Governance role (needed from S9 onwards)
--
--   GOVERNANCE_ADMIN  simulated data-governance team; owns the GOVERNANCE
--                     database, classification tags and masking policies
--
-- Tags and policies (owned by GOVERNANCE_ADMIN, schema GOVERNANCE.POLICIES):
--   PII        plain tag, no propagation; masked by MASK_PII_STRING
--   PII_AUTO   tag with PROPAGATE = ON_DATA_MOVEMENT; masked by MASK_PII_AUTO_STRING
-- Both masking policies reveal values only to PLATFORM_INGEST and the Silver
-- service role (SLD 6.3: the Silver service role reads raw unmasked).
--
-- Run as: USERADMIN, SECURITYADMIN, ACCOUNTADMIN (two account privileges),
--         SYSADMIN, then GOVERNANCE_ADMIN. Idempotent.
-- =============================================================================

use secondary roles none;
set me = (select current_user());

use role useradmin;
create role if not exists governance_admin comment = 'Spike: simulated data-governance team';

use role securityadmin;
grant role governance_admin to role sysadmin;
grant role governance_admin to user identifier($me);

-- Setting a masking policy on a tag needs APPLY MASKING POLICY on the account.
-- Creating a tag with PROPAGATE needs APPLY TAG on the account (observed).
use role accountadmin;
grant apply masking policy on account to role governance_admin;
grant apply tag on account to role governance_admin;

use role sysadmin;
create database if not exists governance comment = 'Spike: classification tags and masking policies';
grant ownership on database governance to role governance_admin copy current grants;
grant usage on warehouse spike_wh to role governance_admin;

use role governance_admin;
use warehouse spike_wh;
create schema if not exists governance.policies;

create tag if not exists governance.policies.pii
  comment = 'PII classification; carried onto derived columns explicitly (dbt post-hook)';
create tag if not exists governance.policies.pii_auto
  propagate = on_data_movement
  comment = 'PII classification; propagated automatically on CTAS and DML';

create masking policy if not exists governance.policies.mask_pii_string
  as (v varchar) returns varchar ->
  case when current_role() in ('PLATFORM_INGEST', 'SVC_SILVER_ERP') then v else '***MASKED***' end;
create masking policy if not exists governance.policies.mask_pii_auto_string
  as (v varchar) returns varchar ->
  case when current_role() in ('PLATFORM_INGEST', 'SVC_SILVER_ERP') then v else '***MASKED***' end;

-- Attach each policy to its tag (errors harmlessly on rerun if already attached)
begin
  alter tag governance.policies.pii set masking policy governance.policies.mask_pii_string;
exception
  when other then null;
end;
begin
  alter tag governance.policies.pii_auto set masking policy governance.policies.mask_pii_auto_string;
exception
  when other then null;
end;

-- PII_DEP (S9e, S9f): propagates through views AND on data movement; the value
-- 'declassified' reveals a column (durable declassification, S9e). PII_AUTO and
-- PII_DECL propagate on data movement only and stop at a view (observed, S9f).
create tag if not exists governance.policies.pii_dep
  propagate = on_dependency_and_data_movement
  comment = 'PII classification; propagates through views and on data movement; value declassified reveals';
create masking policy if not exists governance.policies.mask_pii_dep_string
  as (v varchar) returns varchar ->
  case
    when current_role() in ('PLATFORM_INGEST', 'SVC_SILVER_ERP') then v
    when system$get_tag_on_current_column('governance.policies.pii_dep') = 'declassified' then v
    else '***MASKED***'
  end;
begin
  alter tag governance.policies.pii_dep set masking policy governance.policies.mask_pii_dep_string;
exception
  when other then
    alter tag governance.policies.pii_dep unset masking policy governance.policies.mask_pii_dep_string;
    alter tag governance.policies.pii_dep set masking policy governance.policies.mask_pii_dep_string;
end;

-- Platform tags raw columns; the Silver service role carries tags onto outputs
grant usage on database governance        to role platform_ingest;
grant usage on database governance        to role svc_silver_erp;
grant usage on schema governance.policies to role platform_ingest;
grant usage on schema governance.policies to role svc_silver_erp;
grant apply on tag governance.policies.pii      to role platform_ingest;
grant apply on tag governance.policies.pii_auto to role platform_ingest;
grant apply on tag governance.policies.pii      to role svc_silver_erp;
grant apply on tag governance.policies.pii_auto to role svc_silver_erp;
grant apply on tag governance.policies.pii_dep  to role platform_ingest;
grant apply on tag governance.policies.pii_dep  to role svc_silver_erp;

-- Evidence ---------------------------------------------------------------------
show tags in schema governance.policies;
-- Expect PII and PII_AUTO owned by GOVERNANCE_ADMIN; PII_AUTO shows propagation ON_DATA_MOVEMENT.
