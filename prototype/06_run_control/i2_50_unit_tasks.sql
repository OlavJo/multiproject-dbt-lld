-- =============================================================================
-- Prototype / Increment 2 / Step 50: one task per unit, owned by the unit role
--
-- A task runs as its owner, so a unit's task must be owned by the unit's service role (F1,
-- F2). Stewards run it without holding that role: SILVER_OPERATOR gets OPERATE on the task
-- and starts it with EXECUTE TASK; the run is still the unit role's (IA-7; V-IA-7).
--
-- Prototype choice I2-1 (decided for the prototype 2026-10-12, proposed for RC-1):
--   * tasks live in silver.tasks, a MANAGED ACCESS schema owned by SILVER_SCHEDULER, a
--     utility role that holds every unit role (onboard_unit grants each one to it) and is
--     never held by a person
--   * silver.ops.provision_unit_task(unit), owned by SILVER_SCHEDULER (owner's rights) and
--     called by the operator after onboard_unit:
--       1. creates silver.tasks.publish_<unit>
--       2. hands it to the unit role with no grants on it (INC1.01: a hand-over cannot copy
--          grants without MANAGE GRANTS)
--       3. grants OPERATE and MONITOR to SILVER_OPERATOR, as the schema owner
--   * the task carries the baseline schedule (SLD 12.7) but stays SUSPENDED; resuming
--     schedules is RC-1's decision. The demo starts it with EXECUTE TASK.
--
-- Why a scheduler role (first run, 2026-10-12, INC2.10): in a managed-access schema an object
-- can be handed only to a role SUBORDINATE to the schema owner ("Ownership restriction
-- violation in a managed access schema. Grantee need to be a subordinate role of the schema
-- owner"). Unit roles are not below SILVER_STEWARD, and must not be (F7). The scheduler holds
-- them, like SILVER_CLONER in IA-2 (b); Increment 3 may merge the two.
--
-- Run as: SYSADMIN, SILVER_STEWARD, then SILVER_SCHEDULER (switches itself).
-- Requires: i1_10 and i1_40 rerun (the scheduler role and its unit-role grants), i2_40.
-- Idempotent.
-- =============================================================================

use secondary roles none;

-- Part A: the steward's grants to the scheduler -----------------------------------------
use role silver_steward;
use warehouse lld_wh;

-- First run left a steward-owned silver.tasks with two steward-owned tasks; remove it once
declare
  v_owner varchar;
begin
  show schemas like 'TASKS' in database silver;
  select max("owner") into :v_owner from table(result_scan(last_query_id()));
  if (v_owner = 'SILVER_STEWARD') then
    drop schema silver.tasks;
    return 'dropped the steward-owned silver.tasks from the first run';
  end if;
  return 'nothing to clean up (owner: ' || nvl(v_owner, 'none') || ')';
end;
-- ... and a steward-owned provision_unit_task, which the scheduler could not replace. On later
-- runs the scheduler owns it and this drop is refused, harmlessly.
begin
  drop procedure if exists silver.ops.provision_unit_task(varchar);
exception
  when other then null;
end;

grant usage, create schema on database silver                   to role silver_scheduler;
grant usage, create procedure on schema silver.ops              to role silver_scheduler;
grant usage on database analytics_ops                           to role silver_scheduler;
grant usage on schema analytics_ops.control                     to role silver_scheduler;
grant select on table analytics_ops.control.units               to role silver_scheduler;
grant select on table analytics_ops.control.unit_lease          to role silver_scheduler;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role silver_scheduler;

-- Part B: the scheduler's schema and procedure ---------------------------------------
use role silver_scheduler;

create schema if not exists silver.tasks with managed access;
grant usage on schema silver.tasks to role silver_unit_base;
grant usage on schema silver.tasks to role silver_operator;
grant usage on schema silver.tasks to role silver_provisioner;   -- offboard_unit drops a retired unit's task

create or replace procedure silver.ops.provision_unit_task(p_unit varchar)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  c_task_prefix varchar default 'silver.tasks.publish_';
  c_role_prefix varchar default 'SVC_SILVER_';
  c_warehouse   varchar default 'lld_wh';        -- trial shortcut T3 (OC-1)
  c_schedule    varchar default '60 MINUTE';     -- baseline cadence; the task stays suspended (RC-1)
  v_n           integer default 0;
  v_selector    varchar;
  v_task        varchar;
  v_role        varchar;
  v_note        varchar default 'created';
begin
  if (p_unit is null or not regexp_like(p_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(p_unit, '__')) then
    return 'REFUSED:invalid_unit_name';
  end if;
  select count(*) into :v_n from analytics_ops.control.unit_lease where unit = :p_unit;
  if (v_n = 0) then
    return 'REFUSED:unit_not_onboarded';
  end if;
  select max(selector) into :v_selector from analytics_ops.control.units where unit = :p_unit;
  if (v_selector is null) then
    return 'REFUSED:no_selector';
  end if;

  v_task := c_task_prefix || split_part(p_unit, '.', 2);
  v_role := c_role_prefix || upper(split_part(p_unit, '.', 2));

  -- 1, 2: created and handed over; on a rerun the task exists, owned by the unit role
  begin
    execute immediate 'create task ' || v_task
      || ' warehouse = ' || c_warehouse
      || ' schedule = ''' || c_schedule || ''''
      || ' comment = ''Publishes ' || p_unit || ' (prototype)'''
      || ' as call silver.ops.publish_unit(''' || p_unit || ''')';
  exception
    when other then
      v_note := 'existing';
  end;
  if (v_note = 'created') then
    execute immediate 'grant ownership on task ' || v_task || ' to role ' || v_role;
  end if;

  -- 3: the operator may start and watch it (re-applied on every call)
  execute immediate 'grant operate on task ' || v_task || ' to role silver_operator';
  execute immediate 'grant monitor on task ' || v_task || ' to role silver_operator';

  call analytics_ops.control.log_event(:p_unit, 'TASK_PROVISIONED', null::timestamp_ntz, null::varchar,
    object_construct('task', :v_task, 'owner', :v_role, 'task_note', :v_note));
  return 'TASK:' || v_task || ' owned by ' || v_role || ' (' || v_note || '); OPERATE, MONITOR to SILVER_OPERATOR';
end;
$$;
grant usage on procedure silver.ops.provision_unit_task(varchar) to role silver_operator;

show procedures like 'PROVISION_UNIT_TASK' in schema silver.ops;
