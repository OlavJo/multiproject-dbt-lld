-- =============================================================================
-- Spike S10: consistent reads across publication units
-- See README.md in this folder.
--
-- SLD 10.9: a unit that reads other units' published schemas (the Core module, Tier 1 and 2)
-- runs many queries over minutes. If an upstream unit swaps in its new version in the middle, early
-- models read the old version and later models the new one. Candidate mitigation: at the gate, the
-- downstream unit zero-copy clones each upstream published SCHEMA it reads into a private input
-- schema and builds from the clones (publish_unit core resolves references to core__in_erp,
-- core__in_crm). Depends on S1 (views rebind to their cloned siblings).
--
-- The Core unit has two models that read the same upstream data a minute apart (core_orders_a,
-- then core_orders_b after a 70 s pause) and a test that the two reads agree.
--
--   Part A  the problem: the Core unit built WITHOUT input clones while ERP publishes in the middle
--   Part B  the mitigation: the procedure publishes Core with input clones while ERP publishes
--           in the middle: consistent, older than upstream, the clones gone afterwards
--   Part C  privileges, and rebinding of views in a cloned schema
--   Part D  cost: clone times from query history
-- Requires setup/08 (re-run), setup/10, and the tasks of s08b (silver.ops.s8_task_erp).
-- Run 2 (this version) starts with the corrected selectors (step 0); run 1's findings are in README.md.
-- Run as: PLATFORM_INGEST, SVC_SILVER_ERP, SVC_SILVER_CORE, ANALYST_TIER1, SVC_SILVER_CRM,
-- ACCOUNTADMIN, SILVER_STEWARD (the script switches). About 12 minutes.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- =============================================================================
-- Step 0 (run 2): deploy the corrected selectors, and check that ERP can publish again
-- Run 1 found that the ERP unit's selector (a frozen-input source with children: true) selected the
-- Core models, so every ERP publication failed ("Schema 'CORE' already exists, but current role has no
-- privileges on it") once Core read ERP. Selectors now select a unit by its folder path only.
-- =============================================================================
use role silver_steward;
alter git repository spike_lab.git.spikes_repo fetch;
set sql_add = (select 'alter dbt project silver.ops.silver_layer add version from ''@spike_lab.git.spikes_repo/branches/main/dbt/silver''');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.00', 'Deploy the corrected unit selectors in place (ADD VERSION)', $sql_add, '!ERROR:%');
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.01', 'ERP publishes again with the corrected selector (it selects no Core model)', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');

-- =============================================================================
-- Part A: the problem. ERP publishes while the Core build is between its two reads.
-- =============================================================================
use role platform_ingest;
call raw.control.land_batch('ERP', false);

use role svc_silver_core;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.A0', 'Setup: build schema for the Core unit (clone of its published schema)',
  $$create or replace schema silver.core__build clone silver.core with managed access$$, '!ERROR:%');
set a_sql = 'execute dbt project silver.ops.silver_layer args = ''build --selector unit_core --vars "{publish_unit: core, input_clones: {core: []}}" --target prod_core --target-path target/core_nop --log-path logs/core_nop''';

-- Start the ERP publication (a task: its own session), then the Core build without input clones
use role svc_silver_erp;
execute task silver.ops.s8_task_erp;
use role svc_silver_core;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.A1',
  'Core built WITHOUT input clones while ERP publishes in the middle: the consistency test fails',
  $a_sql, 'ERROR:%same_rows%');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.A2', 'The two reads of the same upstream data (orders seen by core_orders_a and by core_orders_b)',
  $$select 'a=' || a.orders || ' orders, b=' || b.orders || ' orders' from silver.core__build.core_orders_a a, silver.core__build.core_orders_b b$$, null);
call spike_lab.evidence.probe($run_id, 'S10', 'S10.A3', 'Timeline (UTC): ERP swap, and when the two Core models were created',
  $$select 'ERP PUBLISHED ' || to_varchar((select max(event_ts) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED'), 'HH24:MI:SS') || ' | ' ||
     (select listagg(table_name || ' created ' || to_varchar(convert_timezone('UTC', created)::timestamp_ntz, 'HH24:MI:SS'), ' | ') within group (order by table_name) from silver.information_schema.tables where table_schema = 'CORE__BUILD' and table_name like 'CORE_ORDERS_%')$$,
  null);
drop schema if exists silver.core__build;

-- =============================================================================
-- Part B: the mitigation through the publish procedure, with ERP publishing in the middle
-- =============================================================================
use role platform_ingest;
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);
use role svc_silver_erp;
execute task silver.ops.s8_task_erp;
use role svc_silver_core;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B1', 'Publish the Core unit through the procedure (input clones) while ERP publishes in the middle',
  $$call silver.ops.publish_unit('silver.core')$$, 'PUBLISHED');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B2', 'The two reads agree in the published Core unit',
  $$select iff(a.orders = b.orders and a.amount = b.amount and a.contacts = b.contacts and a.accounts = b.accounts, 'CONSISTENT', 'INCONSISTENT') from silver.core.core_orders_a a, silver.core.core_orders_b b$$,
  'CONSISTENT');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B3', 'Core data is OLDER than upstream now (ERP published after the clone was taken)',
  $$select iff((select orders from silver.core.core_orders_a) < (select count(*) from silver.erp.erp_orders_current), 'OLDER_THAN_UPSTREAM', 'SAME_AS_UPSTREAM')$$,
  'OLDER_THAN_UPSTREAM');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B4', 'The ERP swap fell inside the Core run (STARTED < ERP PUBLISHED < Core PUBLISHED), after the clone',
  $$with c as (select max(iff(event_type = 'STARTED', event_ts, null)) as s, max(iff(event_type = 'PUBLISHED', event_ts, null)) as p, max(iff(event_type = 'PUBLISHED', detail:inputs_cloned_at::timestamp_ntz, null)) as cl from analytics_ops.control.publish_log where unit = 'silver.core' and event_ts > dateadd(minute, -15, sysdate())),
         e as (select max(event_ts) as p from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED')
    select iff(c.s < e.p and e.p < c.p, 'ERP_SWAP_INSIDE_CORE_RUN', 'NO_OVERLAP') || '; clone ' || iff(c.cl < e.p, 'before', 'after') || ' the swap' from c, e$$,
  'ERP_SWAP_INSIDE_CORE_RUN; clone before the swap');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B5', 'The PUBLISHED event records the input clones',
  $$select detail:input_clones::varchar from analytics_ops.control.publish_log where unit = 'silver.core' and event_type = 'PUBLISHED' order by event_ts desc limit 1$$,
  'core__in_crm,core__in_erp');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B6', 'The input clones are dropped after the run',
  $$select count(*) from silver.information_schema.schemata where schema_name like 'CORE__IN_%'$$, '0');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B7', 'Core watermark (the minimum of its upstream watermarks at the gate) and the upstream watermarks',
  $$select 'core=' || to_varchar((select watermark from analytics_ops.control.unit_status where unit = 'silver.core'), 'HH24:MI:SS') || ' erp=' || to_varchar((select watermark from analytics_ops.control.unit_status where unit = 'silver.erp'), 'HH24:MI:SS') || ' crm=' || to_varchar((select watermark from analytics_ops.control.unit_status where unit = 'silver.crm'), 'HH24:MI:SS')$$,
  null);
call spike_lab.evidence.probe($run_id, 'S10', 'S10.B8', 'The Core unit has no frozen inputs and no raw access (no freeze ran)',
  $$select count(*) from silver.information_schema.tables where table_schema = 'CORE' and table_name like 'RAW__%'$$, '0');

-- =============================================================================
-- Part C: privileges, and views in a cloned schema
-- =============================================================================
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C1', 'A consumer role cannot clone an upstream unit schema',
  $$create or replace schema silver.s10_probe_consumer clone silver.erp$$, 'ERROR:%');
use role svc_silver_crm;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C2', 'Another unit role cannot clone the ERP unit schema',
  $$create or replace schema silver.s10_probe_crm clone silver.erp$$, 'ERROR:%');
use role svc_silver_core;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C3', 'The Core role (inherits the unit roles) can clone it, frozen inputs included',
  $$create or replace schema silver.s10_probe_in_erp clone silver.erp$$, '!ERROR:%');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C4', 'The clone contains the frozen inputs (visible to the cloning role)',
  $$select iff(count(*) > 0, 'FROZEN_INPUTS_CLONED', 'NONE') from silver.information_schema.tables where table_schema = 'S10_PROBE_IN_ERP' and table_name like 'RAW__%'$$, 'FROZEN_INPUTS_CLONED');

-- ERP publishes again; the clone must not follow it
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C5', 'ERP publishes again (through the procedure)', $$call silver.ops.publish_unit('silver.erp')$$, 'PUBLISHED');
use role svc_silver_core;
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C6', 'A base view in the clone reads the frozen input of the clone, not the published one (S1 rebinding), so it lags',
  $$select iff((select count(*) from silver.s10_probe_in_erp.stg_erp__orders) < (select count(*) from silver.erp.stg_erp__orders), 'ISOLATED_FROM_NEW_PUBLICATION', 'FOLLOWS_PUBLISHED') $$,
  'ISOLATED_FROM_NEW_PUBLICATION');
call spike_lab.evidence.probe($run_id, 'S10', 'S10.C7', 'The view definition in the clone is unchanged (bare identifier)',
  $$select iff(contains(get_ddl('view', 'silver.s10_probe_in_erp.stg_erp__orders'), 'from raw__orders'), 'BARE', 'QUALIFIED')$$, 'BARE');
drop schema if exists silver.s10_probe_in_erp;

-- =============================================================================
-- Part D: cost of the input clones (query history, ACCOUNTADMIN)
-- =============================================================================
use role accountadmin;
insert into spike_lab.evidence.observation
  select $run_id, 'S10', 'S10.D1', 'Schema clone statements in the last 45 minutes: count, and elapsed time (ms)',
         'information_schema.query_history', null,
         'clones=' || count(*) || '; elapsed_ms avg=' || round(avg(total_elapsed_time)) || ' max=' || max(total_elapsed_time),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(spike_lab.information_schema.query_history(end_time_range_start => dateadd(minute, -45, current_timestamp()), result_limit => 10000))
  where (query_text ilike 'create or replace schema silver.core__in_%' or query_text ilike 'create or replace schema silver.s10_probe_in_erp%');

use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by observed_at, case_id;
