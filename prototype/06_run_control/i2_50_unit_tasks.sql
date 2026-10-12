-- =============================================================================
-- Prototype / Increment 2 / Step 50: one task per unit, owned by the unit role
--
-- A task runs as its owner, so a unit's task must be owned by the unit's service role (F1,
-- F2). Stewards run it without holding that role: SILVER_OPERATOR gets OPERATE on the task
-- and starts it with EXECUTE TASK; the run is still the unit role's (IA-7; V-IA-7).
--
-- PROPOSED (RC-1, prototype choice I2-1; to confirm at the Increment 2 review):
--   * tasks live in silver.tasks, a MANAGED ACCESS schema owned by SILVER_STEWARD, not in
--     silver.ops and never in a unit schema (a unit schema is swapped every publication)
--   * silver.ops.provision_unit_task(unit), owned by SILVER_STEWARD (owner's rights) and
--     called by the operator after onboard_unit:
--       1. creates silver.tasks.publish_<unit>
--       2. hands it to the unit role with no grants on it (the Increment 1 finding: a
--          hand-over cannot copy grants without MANAGE GRANTS)
--       3. grants OPERATE and MONITOR to SILVER_OPERATOR
--     Steps 2 and 3 rely on the schema owner's right, in a managed-access schema, to grant
--     on every object in it whoever owns the object. Object owners there cannot.
--   * the task carries the baseline schedule (SLD 12.7) but stays SUSPENDED; resuming
--     schedules is RC-1's decision. The demo starts it with EXECUTE TASK.
--
-- Run as: SILVER_STEWARD. Requires: i1_40, i2_40. Idempotent.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse lld_wh;

create schema if not exists silver.tasks with managed access;
grant usage on schema silver.tasks to role silver_unit_base;
grant usage on schema silver.tasks to role silver_operator;

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
