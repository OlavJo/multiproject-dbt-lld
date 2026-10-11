-- =============================================================================
-- Phase 2 / Step 07: deploy the shared Silver dbt project object
--
-- ONE live-version dbt project object for all Silver units (SLD 3.1):
--   silver.ops.silver_layer, pinned to dbt Core 1.12.3 (decision 2026-10-06; the
--   HLD pin of 1.11.11 is revisited after the spikes).
-- Source: the Git repository object created in setup/03, path dbt/silver.
-- Set $git_ref to the branch or tag holding dbt/silver ('main' once merged).
--
-- Redeploying with CREATE OR REPLACE discards the live version's written-back
-- artifacts and grants; the script restores the grants and logs DEPLOYED.
-- Run as: SILVER_STEWARD. Idempotent.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse spike_wh;

set git_ref = 'main';          -- edit: for an unmerged branch use e.g. 'claude/beautiful-rubin-lftk0g'
set run_id = (select uuid_string());

alter git repository spike_lab.git.spikes_repo fetch;

-- The path is built from $git_ref, so create the object through EXECUTE IMMEDIATE
set create_sql = (select 'create or replace dbt project silver.ops.silver_layer ' ||
  'from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver'' ' ||
  'dbt_version = ''1.12.3''');
call spike_lab.evidence.probe($run_id, 'P2', 'P2.10',
  'Create the Silver dbt project object from Git, pinned to 1.12.3',
  $create_sql, '!ERROR:%');

show dbt projects like 'SILVER_LAYER' in schema silver.ops;
insert into spike_lab.evidence.observation
  select $run_id, 'P2', 'P2.11', 'Silver project object is live-version, pinned',
         'show dbt projects like ''SILVER_LAYER''', 'LIVE',
         "default_version", iff("default_version" ilike 'LIVE', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct(*)
  from table(result_scan(last_query_id()));

-- Unit roles execute it (privilege name to be confirmed by this run)
grant usage on dbt project silver.ops.silver_layer to role svc_silver_erp;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_crm;

-- DEPLOYED event (SLD 12.2): the steward writes it; the commit comes from the object
insert into analytics_ops.control.publish_log (unit, event_type, run_id, detail)
  select u.unit, 'DEPLOYED', $run_id, object_construct('git_ref', $git_ref)
  from analytics_ops.control.units u where u.tier = 'T0';

select case_id, outcome, description, observed, role_name, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by case_id;
