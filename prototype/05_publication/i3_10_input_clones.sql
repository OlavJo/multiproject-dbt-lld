-- =============================================================================
-- Prototype / Increment 3 / Step 10: input clones through a fixed procedure (IA-2 b)
--
-- A unit that reads other Silver units (Core; Tier 1 and 2 units later) builds from zero-copy
-- clones of their published schemas, taken at the gate, so a swap upstream during its build
-- cannot split its reads between two versions (SLD 10.9; spike S10).
--
-- A schema clone needs privileges on every object in the schema, frozen inputs included (F6),
-- which no consumer and no other unit holds. So the clones are taken by procedures owned by
-- SILVER_SCHEDULER, which holds every unit role (decided 2026-10-12: the scheduler doubles as
-- IA-2's SILVER_CLONER; same privileges). Owner's rights:
--
--   silver.ops.take_input_clones(unit)   for each Silver upstream in unit_dependencies:
--                                        create or replace schema silver.<unit>__in_<upstream>
--                                          clone silver.<upstream>;
--                                        grant USAGE on it to the unit's role (derived from the
--                                        unit, never from the caller). Returns the upstream list.
--   silver.ops.drop_input_clones(unit)   drops them (after the run, success or failure)
--
-- The downstream role reads the clone through the upstream reader roles it already holds
-- (onboard_unit, IA-2): cloned objects keep their grants (F5), so it reads exactly the PUBLISHED
-- objects of each declared upstream, not the frozen inputs (verification item V-IA-2).
-- Input clones are private to one run and need not be managed access (LLD 01, 6.3).
--
-- Run as: SILVER_SCHEDULER. Requires: i2_50. Idempotent.
-- =============================================================================

use role silver_scheduler;
use secondary roles none;
use warehouse lld_wh;

create or replace procedure silver.ops.take_input_clones(p_unit varchar)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  c_db          varchar default 'silver';
  c_role_prefix varchar default 'SVC_SILVER_';
  v_schema      varchar;
  v_role        varchar;
  v_ups         varchar default '';
  v_n           integer default 0;
begin
  if (p_unit is null or not regexp_like(p_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(p_unit, '__')) then
    return 'REFUSED:invalid_unit_name';
  end if;
  select count(*) into :v_n from analytics_ops.control.unit_lease where unit = :p_unit;
  if (v_n = 0) then
    return 'REFUSED:unit_not_onboarded';
  end if;
  v_schema := split_part(p_unit, '.', 2);
  v_role   := c_role_prefix || upper(v_schema);

  let c_up cursor for
    select split_part(upstream_unit, '.', 2) as up
    from analytics_ops.control.unit_dependencies
    where unit = ? and upstream_unit like 'silver.%'
      and regexp_like(upstream_unit, 'silver[.][a-z][a-z0-9_]{0,40}') and not contains(upstream_unit, '__')
    order by 1;
  open c_up using (p_unit);
  for r in c_up do
    execute immediate 'create or replace schema ' || c_db || '.' || v_schema || '__in_' || r.up
      || ' clone ' || c_db || '.' || r.up;
    execute immediate 'grant usage on schema ' || c_db || '.' || v_schema || '__in_' || r.up || ' to role ' || v_role;
    v_ups := v_ups || iff(v_ups = '', '', ',') || r.up;
  end for;
  return v_ups;
end;
$$;

create or replace procedure silver.ops.drop_input_clones(p_unit varchar)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  c_db     varchar default 'silver';
  v_schema varchar;
  v_done   varchar default '';
begin
  if (p_unit is null or not regexp_like(p_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(p_unit, '__')) then
    return 'REFUSED:invalid_unit_name';
  end if;
  v_schema := split_part(p_unit, '.', 2);
  let c_up cursor for
    select split_part(upstream_unit, '.', 2) as up
    from analytics_ops.control.unit_dependencies
    where unit = ? and upstream_unit like 'silver.%'
      and regexp_like(upstream_unit, 'silver[.][a-z][a-z0-9_]{0,40}') and not contains(upstream_unit, '__');
  open c_up using (p_unit);
  for r in c_up do
    execute immediate 'drop schema if exists ' || c_db || '.' || v_schema || '__in_' || r.up;
    v_done := v_done || iff(v_done = '', '', ',') || r.up;
  end for;
  return 'DROPPED:' || v_done;
end;
$$;

-- The scheduler reads unit_dependencies (it already reads units and unit_lease, i2_50)
use role silver_steward;
grant select on table analytics_ops.control.unit_dependencies to role silver_scheduler;

use role silver_scheduler;
grant usage on procedure silver.ops.take_input_clones(varchar) to role silver_unit_base;
grant usage on procedure silver.ops.drop_input_clones(varchar) to role silver_unit_base;

show procedures like '%INPUT_CLONES' in schema silver.ops;
