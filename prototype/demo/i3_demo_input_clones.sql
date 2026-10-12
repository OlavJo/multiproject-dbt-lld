-- =============================================================================
-- Prototype / Increment 3 / Demo: consistent reads through input clones (Core)
--
-- What it shows (IA-2 b; SLD 10.9; verification items V-IA-2 and V-IA-3):
--   1. Core is onboarded for publication: its role is granted to the scheduler, its task provisioned.
--   2. The clone procedure, owned by SILVER_SCHEDULER, clones ERP and CRM for Core and grants the
--      clones to SVC_SILVER_CORE. Core reads the PUBLISHED objects in a clone, including a view over
--      a frozen input, but not the frozen inputs, and cannot change the clone (V-IA-2). Core's role,
--      which holds only reader roles of ERP, cannot clone ERP itself (V-IA-3).
--   3. The S10 scenario: Core's build reads its upstreams twice, a minute apart; ERP publishes in
--      between. Core still publishes, both reads agree (same_rows), and Core is older than ERP.
--
-- Case ids INC3.01 to INC3.24.
-- Export: select * from lld_lab.evidence.observation where spike = 'INC3' order by observed_at.
-- Requires: Increment 2 demo state, i3_10, publish_unit replaced (i2_40 rerun), the project
-- redeployed with the Core models (i2_30 rerun).
-- Run as: the switching user. Takes about 6 minutes (three publications, one with a 60 s pause).
-- =============================================================================

use secondary roles none;
set run_id = (select uuid_string());

-- Part 1: Core is configured and gets its task ---------------------------------------------
use role silver_steward;
use warehouse lld_wh;
update analytics_ops.control.units set selector = 'unit_core', dbt_target = 'prod_core' where unit = 'silver.core';

use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.01', 'Operator re-applies Core onboarding (Core role granted to the scheduler)',
  $$call silver.ops.onboard_unit('silver.core')$$, 'ONBOARDED:SVC_SILVER_CORE (schema existing)');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.02', 'Operator provisions the Core task',
  $$call silver.ops.provision_unit_task('silver.core')$$, 'TASK:silver.tasks.publish_core owned by SVC_SILVER_CORE (%); OPERATE, MONITOR to SILVER_OPERATOR');

-- Fresh upstreams: land and publish ERP and CRM
use role platform_ingest;
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);
use role silver_operator;
set t1 = (select sysdate());
execute task silver.tasks.publish_erp;
execute task silver.tasks.publish_crm;
call lld_lab.evidence.wait_for_unit('silver.erp', $t1, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.03', 'ERP published (fresh upstream)', 'wait_for_unit(silver.erp)', 'PUBLISHED', $obs);
call lld_lab.evidence.wait_for_unit('silver.crm', $t1, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.04', 'CRM published (fresh upstream)', 'wait_for_unit(silver.crm)', 'PUBLISHED', $obs);

-- Part 2: the clone procedure, step by step (V-IA-2, V-IA-3) ---------------------------------
-- SYSADMIN calls it here for inspection; in a run, publish_unit calls it as the unit role.
use role sysadmin;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.05', 'The scheduler''s procedure clones ERP and CRM for Core',
  $$call silver.ops.take_input_clones('silver.core')$$, 'crm,erp');

declare v varchar; begin
  show tables in schema silver.core__in_erp;
  select listagg(distinct "owner", ',') within group (order by "owner") into :v from table(result_scan(last_query_id()));
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.06', 'Owner of the cloned tables (V-IA-2 asks who owns them)',
  'show tables in schema silver.core__in_erp', null, $obs);

declare v varchar; begin
  show grants on table silver.core__in_erp.erp_accounts;
  select listagg("privilege" || ':' || "granted_to" || ':' || "grantee_name", ',') within group (order by "privilege") into :v
    from table(result_scan(last_query_id())) where "privilege" <> 'OWNERSHIP';
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.07', 'A cloned table keeps its SELECT grant to the upstream reader role (F5)',
  'show grants on table silver.core__in_erp.erp_accounts', '%SELECT:DATABASE_ROLE:%READER_ERP%', $obs);

declare v varchar; begin
  show grants on schema silver.core__in_erp;
  select listagg("privilege" || ':' || "grantee_name", ',') within group (order by "privilege") into :v
    from table(result_scan(last_query_id())) where "privilege" <> 'OWNERSHIP';
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.08', 'The clone schema is granted (USAGE) to the Core role only',
  'show grants on schema silver.core__in_erp', 'USAGE:SVC_SILVER_CORE', $obs);

use role svc_silver_core;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.09', 'Core reads a published table in its clone of ERP',
  $$select count(*) from silver.core__in_erp.erp_accounts$$, '!ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.10', 'Core reads a view over a frozen input in the clone (the view keeps working)',
  $$select count(*) from silver.core__in_erp.stg_erp__accounts$$, '!ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.11', 'Core cannot read the frozen input itself',
  $$select count(*) from silver.core__in_erp.raw__accounts$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.12', 'Core cannot change its clone (it does not own the objects)',
  $$drop table silver.core__in_erp.erp_accounts$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.13', 'Core cannot write into ERP''s published schema',
  $$create table silver.erp.inc3_should_not_exist (i int)$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.14', 'V-IA-3: Core, holding only ERP''s reader role, cannot clone ERP (fails rather than skipping objects)',
  $$create schema silver.core__via3 clone silver.erp$$, 'ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.15', 'V-IA-3: if that clone was created, how many tables it holds',
  $$select count(*) from silver.information_schema.tables where table_schema = 'CORE__VIA3'$$, null);
drop schema if exists silver.core__via3;

use role sysadmin;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.16', 'The scheduler''s procedure drops Core''s clones',
  $$call silver.ops.drop_input_clones('silver.core')$$, 'DROPPED:%crm%erp%');

-- Part 3: the S10 scenario, ERP publishing in the middle of Core's build --------------------
use role silver_operator;
set t2 = (select sysdate());
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.17', 'Operator starts the Core task',
  $$execute task silver.tasks.publish_core$$, '!ERROR:%');
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role silver_operator;
execute task silver.tasks.publish_erp;

call lld_lab.evidence.wait_for_unit('silver.core', $t2, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.18', 'Core is published from input clones', 'wait_for_unit(silver.core)', 'PUBLISHED', $obs);
call lld_lab.evidence.wait_for_unit('silver.erp', $t2, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC3', 'INC3.19', 'ERP is published meanwhile', 'wait_for_unit(silver.erp)', 'PUBLISHED', $obs);

call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.20', 'The ERP swap fell inside the Core run, after Core''s clones were taken',
  $$select iff(e.event_ts > c.detail:inputs_cloned_at::timestamp_ntz and e.event_ts < c.event_ts, 'INSIDE', 'OUTSIDE')
    from (select * from analytics_ops.control.publish_log where unit = 'silver.core' and event_type = 'PUBLISHED' qualify row_number() over (order by event_ts desc) = 1) c,
         (select * from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'PUBLISHED' qualify row_number() over (order by event_ts desc) = 1) e$$,
  'INSIDE');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.21', 'The Core publication records its input clones',
  $$select max_by(detail:input_clones::varchar, event_ts) from analytics_ops.control.publish_log where unit = 'silver.core' and event_type = 'PUBLISHED'$$,
  'crm,erp');

use role analyst_all;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.22', 'Core''s two reads, a minute apart, agree (one version of ERP for the whole build)',
  $$select count(*) from ((select * from silver.core.core_reads_a minus select * from silver.core.core_reads_b)
                          union all (select * from silver.core.core_reads_b minus select * from silver.core.core_reads_a))$$, '0');
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.23', 'Core is older than ERP: it read the version cloned at its gate',
  $$select iff((select orders from silver.core.core_reads_a) < (select count(*) from silver.erp.erp_orders_current), 'OLDER', 'SAME')$$,
  'OLDER');

use role sysadmin;
call lld_lab.evidence.probe($run_id, 'INC3', 'INC3.24', 'No input clone is left after the run',
  $$select count(*) from silver.information_schema.schemata where startswith(schema_name, 'CORE__IN_')$$, '0');

-- Result -------------------------------------------------------------------------------------
select case_id, outcome, description, observed, role_name, observed_at
from lld_lab.evidence.observation where run_id = $run_id order by case_id;
