-- =============================================================================
-- Spike S8, part 6: is there a way to deploy that keeps the grants and the canonical state?
-- s08e showed that CREATE OR REPLACE DBT PROJECT (a) drops every grant on the object,
-- leaving only the owner, and (b) makes the artifacts of all earlier executions
-- unreachable (SLD 3.2's canonical state is lost at each deployment).
-- Candidates, each tried as an INFO probe (a refusal is a result):
--   1  ALTER DBT PROJECT ... ADD VERSION FROM <git path>    (the documented way to add
--      a version to a versioned object; is it accepted on a live-version object?)
--   2  CREATE OR REPLACE DBT PROJECT ... COPY GRANTS         (not documented for this
--      object; tried anyway)
-- After each: show the object (default version, versions), the grants, and whether a
-- known canonical query id from before can still be located. The script ends by restoring
-- the plain deployment of setup/07 (create or replace, grants, DEPLOYED event), so the
-- object is in the known state whatever happens.
-- Run as: SVC_SILVER_ERP, PLATFORM_INGEST, SILVER_STEWARD (switches itself). About 4 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());
set git_ref = 'main';

-- A fresh canonical execution to track: land a batch and publish ERP -------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.00', 'Publish ERP to get a fresh canonical state', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
set qid = (select detail:state_query_id::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1);
set sql_locate = (select 'select system$locate_dbt_artifacts(''' || $qid || ''')');
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.01', 'Locate that canonical execution before any deployment', $sql_locate, null);

-- Candidate 1: ALTER ... ADD VERSION ---------------------------------------------------------------------
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set sql_add = (select 'alter dbt project silver.ops.silver_layer add version from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.10', 'ALTER DBT PROJECT ... ADD VERSION on the live-version object', $sql_add, null);
show dbt projects like 'SILVER_LAYER' in schema silver.ops;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8f.11', 'The object after ADD VERSION: default version, versions', 'show dbt projects', null,
         'default_version=' || "default_version" || '; dbt_version=' || nvl("dbt_version", '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), object_construct(*)
  from table(result_scan(last_query_id()));
show grants on dbt project silver.ops.silver_layer;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8f.12', 'Grants on the object after ADD VERSION', 'show grants on dbt project', null,
         'rows=' || count(*) || '; grantees=' || nvl(listagg("grantee_name" || ':' || "privilege", ', '), '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), array_agg(object_construct(*))
  from table(result_scan(last_query_id()));
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.13', 'Locate the earlier canonical execution after ADD VERSION', $sql_locate, null);
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.14', 'A unit role executes the object after ADD VERSION',
  $$execute dbt project silver.ops.silver_layer args = 'compile --target prod_erp --target-path target/canonical --log-path logs/canonical'$$, null);

-- Candidate 2: CREATE OR REPLACE ... COPY GRANTS ------------------------------------------------------------
use role silver_steward;
set sql_copy = (select 'create or replace dbt project silver.ops.silver_layer copy grants from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver'' dbt_version = ''1.12.3''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.20', 'CREATE OR REPLACE DBT PROJECT ... COPY GRANTS', $sql_copy, null);
show grants on dbt project silver.ops.silver_layer;
insert into spike_lab.evidence.observation
  select $run_id, 'S8', 'S8f.21', 'Grants on the object after the COPY GRANTS attempt', 'show grants on dbt project', null,
         'rows=' || count(*) || '; grantees=' || nvl(listagg("grantee_name" || ':' || "privilege", ', '), '-'),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), array_agg(object_construct(*))
  from table(result_scan(last_query_id()));

-- Restore the plain deployment of setup/07 -----------------------------------------------------------------------
set create_sql = (select 'create or replace dbt project silver.ops.silver_layer from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver'' dbt_version = ''1.12.3''');
call spike_lab.evidence.probe($run_id, 'S8', 'S8f.90', 'Restore: plain CREATE OR REPLACE (setup/07)', $create_sql, '!ERROR:%');
grant usage on dbt project silver.ops.silver_layer to role svc_silver_erp;
grant usage on dbt project silver.ops.silver_layer to role svc_silver_crm;
insert into analytics_ops.control.publish_log (unit, event_type, run_id, detail)
  select u.unit, 'DEPLOYED', $run_id, object_construct('git_ref', $git_ref, 'by', 's08f')
  from analytics_ops.control.units u where u.tier = 'T0';

select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
