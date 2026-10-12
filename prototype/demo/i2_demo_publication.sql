-- =============================================================================
-- Prototype / Increment 2 / Demo: first publications under the unit roles
--
-- What it shows (LLD 01, 5.3, 6.2; verification items V-IA-1 and V-IA-7):
--   1. The operator provisions each unit's task; the task is owned by the unit role and the
--      operator holds OPERATE on it (prototype choice I2-1).
--   2. The platform lands a batch. The operator starts the ERP task with EXECUTE TASK; the
--      run is the unit role's (V-IA-7). It freezes, builds and publishes through
--      silver.ops.publish_unit.
--   3. ANALYST_ALL reads the published ERP and CRM tables through silver.reader; ANALYST_HR
--      cannot. SELECT comes from dbt grants to the unit's reader DATABASE role, schema USAGE
--      from the publish procedure's grant-swap-revoke (V-IA-1, F3).
--   4. A second batch and a second publication: the incremental model keeps its grant
--      across clone and swap and dbt's grant step (V-IA-1); the CDC update lands.
--   5. With nothing new, the task skips (gate condition 2).
--
-- Case ids INC2.10 to INC2.31 (INC2.01, 02 are in i2_30).
-- Export: select * from lld_lab.evidence.observation where spike = 'INC2' order by observed_at.
-- Requires: Increment 1 demo state (units onboarded, consumers granted), i2_10 to i2_50.
-- Each EXECUTE TASK runs in the background; the demo waits for the unit's next terminal event
-- (PUBLISHED, FAILED or SKIPPED) for up to 10 minutes.
-- Run as: the switching user.
-- =============================================================================

use secondary roles none;
set run_id = (select uuid_string());

-- Lab helper: wait for a unit's next terminal event after a point in time --------------------
use role sysadmin;
use warehouse lld_wh;
create or replace procedure lld_lab.evidence.wait_for_unit(p_unit varchar, p_since timestamp_ntz, p_timeout_s integer)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_event varchar;
  v_waited integer default 0;
begin
  while (v_waited < p_timeout_s) do
    select max_by(event_type || ':' || coalesce(detail:stage::varchar, detail:reason::varchar, ''), event_ts)
      into :v_event
      from analytics_ops.control.publish_log
      where unit = :p_unit and event_ts > :p_since and event_type in ('PUBLISHED', 'FAILED', 'SKIPPED');
    if (v_event is not null) then
      return rtrim(v_event, ':');
    end if;
    select system$wait(10);
    v_waited := v_waited + 10;
  end while;
  return 'TIMEOUT';
end;
$$;
grant usage on procedure lld_lab.evidence.wait_for_unit(varchar, timestamp_ntz, integer) to role silver_operator;

-- Part 1: configuration (ops repository, SLD 12.3) and the units' tasks ---------------------
use role silver_steward;
update analytics_ops.control.units set selector = 'unit_erp', dbt_target = 'prod_erp' where unit = 'silver.erp';
update analytics_ops.control.units set selector = 'unit_crm', dbt_target = 'prod_crm' where unit = 'silver.crm';

use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.10', 'Operator provisions the ERP task',
  $$call silver.ops.provision_unit_task('silver.erp')$$, 'TASK:silver.tasks.publish_erp owned by SVC_SILVER_ERP (%); OPERATE, MONITOR to SILVER_OPERATOR');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.11', 'Operator provisions the CRM task',
  $$call silver.ops.provision_unit_task('silver.crm')$$, 'TASK:silver.tasks.publish_crm owned by SVC_SILVER_CRM (%); OPERATE, MONITOR to SILVER_OPERATOR');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.12', 'A unit with no selector gets no task',
  $$call silver.ops.provision_unit_task('silver.core')$$, 'REFUSED:no_selector');

use role sysadmin;
show tasks in schema silver.tasks;
set obs = (select listagg("name" || ':' || "owner" || ':' || "state", ',') within group (order by "name")
           from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.13', 'Each task is owned by its unit role and suspended',
  'show tasks in schema silver.tasks', 'PUBLISH_CRM:SVC_SILVER_CRM:suspended,PUBLISH_ERP:SVC_SILVER_ERP:suspended', $obs);

use role silver_operator;
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.14', 'The operator cannot run the publish procedure itself',
  $$call silver.ops.publish_unit('silver.erp')$$, 'ERROR:%');

-- Part 2: land, then publish ERP and CRM through their tasks ---------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
call raw.control.land_batch('CRM', false);

use role silver_operator;
set t0 = (select sysdate());
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.15', 'The operator starts the ERP task (OPERATE, V-IA-7)',
  $$execute task silver.tasks.publish_erp$$, '!ERROR:%');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.16', 'Operator starts the CRM task',
  $$execute task silver.tasks.publish_crm$$, '!ERROR:%');
call lld_lab.evidence.wait_for_unit('silver.erp', $t0, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.17', 'ERP is published by its task', 'wait_for_unit(silver.erp)', 'PUBLISHED', $obs);
call lld_lab.evidence.wait_for_unit('silver.crm', $t0, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.18', 'CRM is published by its task', 'wait_for_unit(silver.crm)', 'PUBLISHED', $obs);
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.19', 'The ERP run was the unit role''s, not the operator''s (V-IA-7)',
  $$select max_by(detail:role::varchar, event_ts) from analytics_ops.control.publish_log where unit = 'silver.erp' and event_type = 'STARTED'$$,
  'SVC_SILVER_ERP');

-- Part 3: consumers ------------------------------------------------------------------------
use role analyst_all;
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.20', 'ANALYST_ALL reads the published ERP accounts (1 initial + 2 landed)',
  $$select count(*) from silver.erp.erp_accounts$$, '3');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.21', 'ANALYST_ALL reads current ERP orders (CDC: one row per order)',
  $$select count(*) from silver.erp.erp_orders_current$$, '3');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.22', 'ANALYST_ALL reads the published CRM contacts',
  $$select count(*) from silver.crm.crm_contacts$$, '3');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.23', 'ANALYST_ALL cannot read the frozen inputs',
  $$select count(*) from silver.erp.raw__accounts$$, 'ERROR:%');
use role analyst_hr;
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.24', 'ANALYST_HR cannot read ERP',
  $$select count(*) from silver.erp.erp_accounts$$, 'ERROR:%');

use role sysadmin;
-- In a block, so a missing table is recorded as a FAIL instead of stopping the demo
declare v varchar; begin
  show grants on table silver.erp.erp_accounts;
  select listagg("privilege" || ':' || "granted_to" || ':' || "grantee_name", ',') within group (order by "privilege") into :v
    from table(result_scan(last_query_id())) where "privilege" <> 'OWNERSHIP';
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.25', 'dbt grants SELECT to the reader database role (V-IA-1)',
  'show grants on table silver.erp.erp_accounts', 'SELECT:DATABASE_ROLE:%READER_ERP%', $obs);
declare v varchar; begin
  show grants on schema silver.erp__build;
  select count(*)::varchar into :v from table(result_scan(last_query_id()))
    where "privilege" = 'USAGE' and "grantee_name" ilike '%READER_ERP%';
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.26', 'After the swap the reader holds no USAGE on the build schema (F3)',
  'show grants on schema silver.erp__build', '0', $obs);

-- Part 4: a second batch and a second ERP publication ---------------------------------------
use role platform_ingest;
call raw.control.land_batch('ERP', false);
use role silver_operator;
set t1 = (select sysdate());
execute task silver.tasks.publish_erp;
call lld_lab.evidence.wait_for_unit('silver.erp', $t1, 600);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.27', 'ERP is published a second time', 'wait_for_unit(silver.erp)', 'PUBLISHED', $obs);

use role analyst_all;
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.28', 'ANALYST_ALL reads the second publication (5 accounts)',
  $$select count(*) from silver.erp.erp_accounts$$, '5');
call lld_lab.evidence.probe($run_id, 'INC2', 'INC2.29', 'The incremental model merged the CDC update (order 1 now RETURNED)',
  $$select status from silver.erp.erp_orders_current where order_id = 1$$, 'RETURNED');
use role sysadmin;
declare v varchar; begin
  show grants on table silver.erp.erp_orders_current;
  select listagg("privilege" || ':' || "granted_to" || ':' || "grantee_name", ',') within group (order by "privilege") into :v
    from table(result_scan(last_query_id())) where "privilege" <> 'OWNERSHIP';
  return v;
exception when other then return 'ERROR: ' || sqlerrm;
end;
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.30', 'The incremental model still grants SELECT to the reader role after clone, dbt and swap (V-IA-1)',
  'show grants on table silver.erp.erp_orders_current', 'SELECT:DATABASE_ROLE:%READER_ERP%', $obs);

-- Part 5: nothing new, nothing built --------------------------------------------------------
use role silver_operator;
set t2 = (select sysdate());
execute task silver.tasks.publish_erp;
call lld_lab.evidence.wait_for_unit('silver.erp', $t2, 300);
set obs = (select $1 from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC2', 'INC2.31', 'With no new input the task skips (gate condition 2)', 'wait_for_unit(silver.erp)', 'SKIPPED:nothing_new', $obs);

-- Result -------------------------------------------------------------------------------------
use role sysadmin;
select case_id, outcome, description, observed, role_name, observed_at
from lld_lab.evidence.observation where run_id = $run_id order by case_id;
