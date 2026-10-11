-- =============================================================================
-- Prototype / Increment 0: tear down the spike objects
--
-- Removes everything the spikes created, so the prototype starts clean:
--   databases  RAW, SILVER, ANALYTICS_OPS, GOVERNANCE (with their schemas, tasks,
--              database roles, dbt project objects, tags and masking policies)
--   schema     SPIKE_LAB.HELLO (the hello dbt project)
--   roles      PLATFORM_INGEST, SILVER_STEWARD, SVC_SILVER_ERP, SVC_SILVER_CRM,
--              SVC_SILVER_CORE, ANALYST_TIER1, GOVERNANCE_ADMIN
--
-- Keeps, because the prototype reuses them:
--   warehouse SPIKE_WH and resource monitor SPIKE_RM
--   SPIKE_LAB.EVIDENCE (the OBSERVATION table, with every spike row, and PROBE)
--   SPIKE_LAB.GIT (the GitHub secret and Git repository object) and the API
--   integration SPIKE_GIT_API, so the token need not be entered again. Their
--   ownership moves from SILVER_STEWARD to SYSADMIN before that role is dropped.
--
-- The spike evidence is committed under evidence/ in the spikes repository
-- (OlavJo/dbt-spikes-2026), and its spike scripts can rebuild the spike
-- objects (setup/00 to 10), so nothing is lost. Dropped
-- databases stay recoverable with UNDROP for their Time Travel period.
--
-- SAFETY: the drops run only if v_confirm below is edited to 'YES'.
-- Run as: ACCOUNTADMIN (it inherits every spike role through SYSADMIN).
-- Idempotent: every drop is IF EXISTS or guarded.
-- =============================================================================

use role accountadmin;
use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- 1. Review what will be removed ------------------------------------------------
show databases;
select "name", "owner", "created_on" from table(result_scan(last_query_id()))
where "name" in ('RAW', 'SILVER', 'ANALYTICS_OPS', 'GOVERNANCE');

show roles;
select "name", "owner", "created_on" from table(result_scan(last_query_id()))
where "name" in ('PLATFORM_INGEST', 'SILVER_STEWARD', 'SVC_SILVER_ERP', 'SVC_SILVER_CRM',
                 'SVC_SILVER_CORE', 'ANALYST_TIER1', 'GOVERNANCE_ADMIN');

-- 2. Teardown (guarded) ---------------------------------------------------------
declare
  v_confirm varchar default 'NO';   -- EDIT to 'YES' to tear down
  v_notes   varchar default '';
begin
  if (v_confirm <> 'YES') then
    return 'NOT RUN: edit v_confirm to YES';
  end if;

  -- Tags with masking policies attached are detached first, so the GOVERNANCE
  -- database drops cleanly. Each step tolerates the object being gone already.
  begin alter tag governance.policies.pii      unset masking policy governance.policies.mask_pii_string;      exception when other then v_notes := v_notes || ' pii;'; end;
  begin alter tag governance.policies.pii_auto unset masking policy governance.policies.mask_pii_auto_string; exception when other then v_notes := v_notes || ' pii_auto;'; end;
  begin alter tag governance.policies.pii_decl unset masking policy governance.policies.mask_pii_decl_string; exception when other then v_notes := v_notes || ' pii_decl;'; end;
  begin alter tag governance.policies.pii_dep  unset masking policy governance.policies.mask_pii_dep_string;  exception when other then v_notes := v_notes || ' pii_dep;'; end;

  -- Silver first (tasks, project object, unit schemas), then its upstreams
  drop database if exists silver;
  drop database if exists analytics_ops;
  drop database if exists raw;
  drop database if exists governance;

  drop schema if exists spike_lab.hello;
  begin drop masking policy if exists spike_lab.evidence.mp_edition_check; exception when other then v_notes := v_notes || ' mp_edition_check;'; end;

  -- Keep the Git objects: move them to SYSADMIN before their owner role is dropped
  begin grant ownership on git repository spike_lab.git.spikes_repo to role sysadmin copy current grants; exception when other then v_notes := v_notes || ' repo:' || sqlerrm || ';'; end;
  begin grant ownership on secret spike_lab.git.github_pat          to role sysadmin copy current grants; exception when other then v_notes := v_notes || ' secret:' || sqlerrm || ';'; end;
  begin grant ownership on schema spike_lab.git                     to role sysadmin copy current grants; exception when other then v_notes := v_notes || ' git schema:' || sqlerrm || ';'; end;

  drop role if exists svc_silver_core;
  drop role if exists svc_silver_crm;
  drop role if exists svc_silver_erp;
  drop role if exists analyst_tier1;
  drop role if exists silver_steward;
  drop role if exists platform_ingest;
  drop role if exists governance_admin;

  return 'DONE' || iff(v_notes = '', '', ' (skipped:' || v_notes || ')');
end;

-- 3. Evidence ---------------------------------------------------------------------
-- Each SHOW result is read into $obs and turned into a constant query $q for the
-- probe, so it lands in the evidence table like every other observation.
show databases;
set obs = (select count(*) from table(result_scan(last_query_id()))
           where "name" in ('RAW', 'SILVER', 'ANALYTICS_OPS', 'GOVERNANCE'));
set q = (select 'select ' || $obs);
call spike_lab.evidence.probe($run_id, 'INC0', 'INC0.01', 'No spike databases remain', $q, '0');

show roles;
set obs = (select count(*) from table(result_scan(last_query_id()))
           where "name" in ('PLATFORM_INGEST', 'SILVER_STEWARD', 'SVC_SILVER_ERP', 'SVC_SILVER_CRM',
                            'SVC_SILVER_CORE', 'ANALYST_TIER1', 'GOVERNANCE_ADMIN'));
set q = (select 'select ' || $obs);
call spike_lab.evidence.probe($run_id, 'INC0', 'INC0.02', 'No spike roles remain', $q, '0');

show git repositories in schema spike_lab.git;
set obs = (select nvl(max("owner"), '<none>') from table(result_scan(last_query_id())) where "name" = 'SPIKES_REPO');
set q = (select 'select ''' || $obs || '''');
call spike_lab.evidence.probe($run_id, 'INC0', 'INC0.03', 'Git repository object kept, owned by SYSADMIN', $q, 'SYSADMIN');

show secrets in schema spike_lab.git;
set obs = (select nvl(max("owner"), '<none>') from table(result_scan(last_query_id())) where "name" = 'GITHUB_PAT');
set q = (select 'select ''' || $obs || '''');
call spike_lab.evidence.probe($run_id, 'INC0', 'INC0.04', 'GitHub secret kept, owned by SYSADMIN', $q, 'SYSADMIN');

call spike_lab.evidence.probe($run_id, 'INC0', 'INC0.05', 'Spike evidence kept',
  $$select count(*) from spike_lab.evidence.observation where spike not like 'INC%'$$, '!0');

select case_id, outcome, description, observed
from spike_lab.evidence.observation where run_id = $run_id order by case_id;
