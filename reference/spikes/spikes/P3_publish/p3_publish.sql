-- =============================================================================
-- Phase 2: the publish procedure, happy path and gates (SLD 10.4, 12.4, 12.7)
-- See README.md in this folder. Requires setup/08 and the state left by
-- p2_smoke.sql rounds 1 to 3 (ERP published manually, 3 ERP batches landed,
-- CRM never published). Not idempotent in its expectations.
--
--   A  first call: gate passes (DEPLOYED, nothing published through the log), publishes
--   B  second call at once: SKIPPED nothing_new
--   C  new batch lands, call: PUBLISHED, incremental picks up the batch
--   D  lease held by another run: SKIPPED locked, lease untouched
--   E  upstream too stale for its tolerance: SKIPPED stale_upstream
--   F  the second unit (CRM), under its own role and target
--   G  run-control state after all of it
-- Run as: SVC_SILVER_ERP, SVC_SILVER_CRM, PLATFORM_INGEST, SILVER_STEWARD (switches itself).
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- A: first publication through the procedure --------------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.A1', 'First call publishes ERP (gate: DEPLOYED event, upstream fresh)',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.A2', 'Log: last events for silver.erp are STARTED then PUBLISHED',
  $$select listagg(event_type, ',') within group (order by event_ts) from (select event_type, event_ts from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type in ('STARTED','PUBLISHED') order by event_ts desc limit 2)$$,
  'STARTED,PUBLISHED');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.A3', 'PUBLISHED watermark equals the raw ERP watermark (latest landing-complete)',
  $$select iff((select max(watermark) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED') = (select max(completed_at) from analytics_ops.control.v_landing_complete where source_system = 'ERP'), 'EQUAL', 'DIFFERENT')$$,
  'EQUAL');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.A4', 'Canonical compile after the swap: result recorded in the PUBLISHED event',
  $$select detail::varchar from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' order by event_ts desc limit 1$$,
  null);
call spike_lab.evidence.probe($run_id, 'P3', 'P3.A5', 'Lease is free after the run',
  $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');

-- B: nothing new ---------------------------------------------------------------------------
call spike_lab.evidence.probe($run_id, 'P3', 'P3.B1', 'Second call immediately: nothing new to build',
  $$call silver.ops.publish_unit('silver.erp')$$, 'SKIPPED:nothing_new');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.B2', 'Lease free after a skipped run',
  $$select iff(run_id is null, 'FREE', 'HELD') from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'FREE');

-- C: a new batch lands ------------------------------------------------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.C1', 'After a new ERP batch: publishes again',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.C2', 'Consumer reads the new batch (4 batches landed: 8 orders)',
  $$select count(*) from silver.erp.erp_orders_current$$, '8');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.C3', 'Consumer sees the email masked after the procedure publish',
  $$select email from silver.erp.erp_accounts where account_id = 1$$, '***MASKED***');
use role svc_silver_erp;

-- D: lease held by another run -------------------------------------------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.D1', 'Another run holds the lease',
  $$call analytics_ops.control.acquire_lease('silver.erp', 'other-run')$$, 'true');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.D2', 'Call while the lease is held: skipped, not queued',
  $$call silver.ops.publish_unit('silver.erp')$$, 'SKIPPED:locked');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.D3', 'The holder is still the other run',
  $$select run_id from analytics_ops.control.unit_lease where unit = 'silver.erp'$$, 'other-run');
call spike_lab.evidence.probe($run_id, 'P3', 'P3.D4', 'Release by the holder',
  $$call analytics_ops.control.release_lease('silver.erp', 'other-run')$$, 'true');

-- E: upstream stale ---------------------------------------------------------------------------------
use role silver_steward;
update analytics_ops.control.unit_dependencies set max_age_hours = 0 where unit = 'silver.erp';
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.E1', 'Upstream older than tolerance: skipped',
  $$call silver.ops.publish_unit('silver.erp')$$, 'SKIPPED:stale_upstream');
use role silver_steward;
update analytics_ops.control.unit_dependencies set max_age_hours = 24 where unit = 'silver.erp';
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.E2', 'Tolerance restored: the waiting batch publishes (5 batches: 10 orders)',
  $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- F: the second unit, under its own role and target ----------------------------------------------------
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.F1', 'CRM unit publishes under SVC_SILVER_CRM (prod_crm)',
  $$call silver.ops.publish_unit('silver.crm')$$, 'PUBLISHED');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.F2', 'Consumer reads published CRM contacts',
  $$select count(*) from silver.crm.crm_contacts$$, '2');

-- G: run-control state ----------------------------------------------------------------------------------------
use role silver_steward;
call spike_lab.evidence.probe($run_id, 'P3', 'P3.G1', 'Events per type for the two Silver units',
  $$select listagg(unit || ':' || event_type || '=' || n, '; ') within group (order by unit, event_type) from (select unit, event_type, count(*) n from analytics_ops.control.publish_log where unit in ('silver.erp','silver.crm') group by unit, event_type)$$,
  null);
insert into spike_lab.evidence.observation
  select $run_id, 'P3', 'P3.G2', 'unit_status after the run', 'select * from analytics_ops.control.unit_status', null,
         'units=' || count(*), 'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(),
         array_agg(object_construct(*))
  from analytics_ops.control.unit_status;

select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
