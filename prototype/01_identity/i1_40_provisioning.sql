-- =============================================================================
-- Prototype / Increment 1 / Step 40: steward self-service onboarding of units
--
-- Implements LLD 01, Section 7.1.1 (decision IA-1) and 7.3 (IA-3):
--
--   silver.ops.onboard_unit(unit)          create or re-apply a Silver unit's roles,
--                                          reader role, grants and published schema
--   silver.ops.offboard_unit(unit)         retire a unit (refused while others depend on it)
--   silver.ops.grant_unit_reader(reader, role)    give a consumer role a reader role
--   silver.ops.revoke_unit_reader(reader, role)   and take it away
--
-- All four are OWNER'S RIGHTS procedures owned by SILVER_PROVISIONER, callable by
-- SILVER_OPERATOR. Stewards never hold CREATE ROLE themselves. Every name used in
-- dynamic SQL is either validated against a pattern or read from the reviewed
-- configuration in analytics_ops.control.
--
-- What onboard_unit does NOT do, by design (LLD 01, 7.1.1): grant raw access (the
-- platform grants raw.reader_<source>) and grant clear-value access (governance).
--
-- Part A runs as SILVER_STEWARD (grants on what it owns); Part B as
-- SILVER_PROVISIONER (trial shortcut T1: run by a person; in production by the
-- deployment pipeline).
-- Requires: i1_10, i1_30. Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse lld_wh;

-- Part A: the steward grants the provisioner, the unit base role and the operator ------
use role silver_steward;

-- Procedures and (from Increment 2) the project object. Not managed access: the
-- provisioner grants USAGE on the procedures it owns.
create schema if not exists silver.ops;

-- SILVER_PROVISIONER: create schemas and reader roles in silver; read configuration;
-- maintain lease rows; log events
grant usage, create schema, create database role on database silver to role silver_provisioner;
grant usage, create procedure on schema silver.ops                to role silver_provisioner;
grant usage on database analytics_ops                             to role silver_provisioner;
grant usage on schema analytics_ops.control                       to role silver_provisioner;
grant select on table analytics_ops.control.units                 to role silver_provisioner;
grant select on table analytics_ops.control.unit_dependencies     to role silver_provisioner;
grant select, insert, delete on table analytics_ops.control.unit_lease to role silver_provisioner;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role silver_provisioner;

-- SILVER_UNIT_BASE: what every unit role needs (LLD 01, 5.3). Increment 2 adds the
-- project object, the publish procedure and the lease procedures.
grant usage, create schema on database silver                     to role silver_unit_base;
grant usage on schema silver.ops                                  to role silver_unit_base;
grant usage on database analytics_ops                             to role silver_unit_base;
grant usage on schema analytics_ops.control                       to role silver_unit_base;
grant select on table analytics_ops.control.units                 to role silver_unit_base;
grant select on table analytics_ops.control.unit_dependencies     to role silver_unit_base;
grant select on table analytics_ops.control.publish_log           to role silver_unit_base;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role silver_unit_base;

-- SILVER_OPERATOR: read run control, call the provisioning procedures (granted in Part B)
grant usage on database silver                                    to role silver_operator;
grant usage on schema silver.ops                                  to role silver_operator;
grant usage on database analytics_ops                             to role silver_operator;
grant usage on schema analytics_ops.control                       to role silver_operator;
grant select on table analytics_ops.control.units                 to role silver_operator;
grant select on table analytics_ops.control.unit_dependencies     to role silver_operator;
grant select on table analytics_ops.control.publish_log           to role silver_operator;
grant select on table analytics_ops.control.unit_lease            to role silver_operator;

-- Part B: the provisioner's objects -------------------------------------------------
use role silver_provisioner;

-- The aggregate reader: every non-sensitive unit's reader role (LLD 01, 7.3)
create database role if not exists silver.reader;

create or replace procedure silver.ops.onboard_unit(p_unit varchar)
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
  v_reader      varchar;
  v_n           integer default 0;
  v_tier        varchar;
  v_sensitive   boolean default false;
  v_bad         integer default 0;
  v_missing     integer default 0;
  v_schema_note varchar default 'created';
  v_ups         varchar default '';
begin
  -- 1. Validate: a well-formed Silver unit name, present in the reviewed configuration
  if (p_unit is null or not regexp_like(p_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(p_unit, '__')) then
    return 'REFUSED:invalid_unit_name';
  end if;
  select count(*), max(tier), boolor_agg(coalesce(sensitive, false))
    into :v_n, :v_tier, :v_sensitive
    from analytics_ops.control.units where unit = :p_unit;
  if (v_n = 0) then
    return 'REFUSED:not_in_units';
  end if;
  if (v_tier not in ('T0', 'T0.5')) then
    return 'REFUSED:not_a_silver_unit';
  end if;
  -- Silver upstreams must be well formed and onboarded already (their reader roles are granted below)
  select count_if(not regexp_like(d.upstream_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(d.upstream_unit, '__')),
         count_if(l.unit is null)
    into :v_bad, :v_missing
    from analytics_ops.control.unit_dependencies d
    left join (select distinct unit from analytics_ops.control.unit_lease) l on l.unit = d.upstream_unit
    where d.unit = :p_unit and d.upstream_unit like 'silver.%';
  if (v_bad > 0) then
    return 'REFUSED:invalid_upstream_name';
  end if;
  if (v_missing > 0) then
    return 'REFUSED:upstream_not_onboarded';
  end if;

  v_schema := split_part(p_unit, '.', 2);
  v_role   := c_role_prefix || upper(v_schema);
  v_reader := c_db || '.reader_' || v_schema;

  -- 2. The service role, with the common privileges and the task privilege
  execute immediate 'create role if not exists ' || v_role || ' comment = ''Service role of the Silver unit ' || p_unit || '''';
  execute immediate 'grant role ' || v_role || ' to role sysadmin';
  execute immediate 'grant role silver_unit_base to role ' || v_role;
  execute immediate 'grant role task_runner to role ' || v_role;

  -- 3. The unit's reader role; in the aggregate reader unless the unit is sensitive
  execute immediate 'create database role if not exists ' || v_reader;
  if (v_sensitive) then
    begin
      execute immediate 'revoke database role ' || v_reader || ' from database role ' || c_db || '.reader';
    exception
      when other then null;   -- was not granted
    end;
  else
    execute immediate 'grant database role ' || v_reader || ' to database role ' || c_db || '.reader';
  end if;

  -- 4. Reader roles of the Silver upstreams: consumer-level access for input clones (IA-2)
  let c_up cursor for
    select split_part(upstream_unit, '.', 2) as up
    from analytics_ops.control.unit_dependencies
    where unit = ? and upstream_unit like 'silver.%'
    order by 1;
  open c_up using (p_unit);
  for r in c_up do
    execute immediate 'grant database role ' || c_db || '.reader_' || r.up || ' to role ' || v_role;
    v_ups := v_ups || iff(v_ups = '', '', ',') || r.up;
  end for;

  -- 5. The published schema: created here, reader USAGE granted, then handed to the unit role.
  -- On a rerun it exists already, owned by the unit role, and is left alone.
  begin
    execute immediate 'create schema ' || c_db || '.' || v_schema || ' with managed access';
  exception
    when other then
      v_schema_note := 'existing';
  end;
  if (v_schema_note = 'created') then
    execute immediate 'grant usage on schema ' || c_db || '.' || v_schema || ' to database role ' || v_reader;
    execute immediate 'grant ownership on schema ' || c_db || '.' || v_schema || ' to role ' || v_role || ' copy current grants';
  end if;

  -- 6. Lease row and the ONBOARDED event
  insert into analytics_ops.control.unit_lease (unit)
    select u.unit from analytics_ops.control.units u
    where u.unit = :p_unit
      and not exists (select 1 from analytics_ops.control.unit_lease l where l.unit = :p_unit);
  call analytics_ops.control.log_event(:p_unit, 'ONBOARDED', null::timestamp_ntz, null::varchar,
    object_construct('role', :v_role, 'reader', :v_reader, 'sensitive', :v_sensitive,
                     'upstream_readers', :v_ups, 'schema', :v_schema_note));
  return 'ONBOARDED:' || v_role || ' (schema ' || v_schema_note || ')';
end;
$$;

create or replace procedure silver.ops.offboard_unit(p_unit varchar)
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
  v_reader      varchar;
  v_deps        varchar;
begin
  if (p_unit is null or not regexp_like(p_unit, 'silver[.][a-z][a-z0-9_]{0,40}') or contains(p_unit, '__')) then
    return 'REFUSED:invalid_unit_name';
  end if;
  select listagg(unit, ',') within group (order by unit) into :v_deps
    from analytics_ops.control.unit_dependencies where upstream_unit = :p_unit;
  if (v_deps is not null and v_deps <> '') then
    return 'REFUSED:has_dependents:' || v_deps;
  end if;

  v_schema := split_part(p_unit, '.', 2);
  v_role   := c_role_prefix || upper(v_schema);
  v_reader := c_db || '.reader_' || v_schema;

  -- Dropping the role passes ownership of its objects (the unit's schemas) to the
  -- role executing the drop, this procedure's owner, which then drops them.
  -- Dropped schemas stay recoverable with UNDROP for their retention period.
  execute immediate 'drop role if exists ' || v_role;
  execute immediate 'drop schema if exists ' || c_db || '.' || v_schema || '__build';
  execute immediate 'drop schema if exists ' || c_db || '.' || v_schema;
  execute immediate 'drop database role if exists ' || v_reader;

  delete from analytics_ops.control.unit_lease where unit = :p_unit;
  call analytics_ops.control.log_event(:p_unit, 'OFFBOARDED', null::timestamp_ntz, null::varchar,
    object_construct('role', :v_role, 'reader', :v_reader));
  return 'OFFBOARDED:' || v_role;
end;
$$;

-- p_reader is 'silver' (the aggregate reader: every non-sensitive unit) or a unit, 'silver.erp'.
-- Service roles are refused: a unit reads its upstreams through unit_dependencies (onboard_unit).
create or replace procedure silver.ops.grant_unit_reader(p_reader varchar, p_role varchar)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  c_db       varchar default 'silver';
  v_db_role  varchar;
  v_role     varchar;
  v_n        integer default 0;
  v_sensitive boolean default false;
begin
  v_role := upper(p_role);
  if (v_role is null or not regexp_like(v_role, '[A-Z][A-Z0-9_]{0,200}') or startswith(v_role, 'SVC_')) then
    return 'REFUSED:invalid_role';
  end if;
  if (p_reader = c_db) then
    v_db_role := c_db || '.reader';
  elseif (regexp_like(p_reader, 'silver[.][a-z][a-z0-9_]{0,40}') and not contains(p_reader, '__')) then
    select count(*) into :v_n from analytics_ops.control.unit_lease where unit = :p_reader;
    if (v_n = 0) then
      return 'REFUSED:unit_not_onboarded';
    end if;
    select boolor_agg(coalesce(sensitive, false)) into :v_sensitive
      from analytics_ops.control.units where unit = :p_reader;
    v_db_role := c_db || '.reader_' || split_part(p_reader, '.', 2);
  else
    return 'REFUSED:invalid_reader';
  end if;

  execute immediate 'grant database role ' || v_db_role || ' to role ' || v_role;
  call analytics_ops.control.log_event(:p_reader, 'ACCESS_GRANTED', null::timestamp_ntz, null::varchar,
    object_construct('reader', :v_db_role, 'role', :v_role, 'sensitive', :v_sensitive));
  return 'GRANTED:' || v_db_role || ' to ' || v_role;
end;
$$;

create or replace procedure silver.ops.revoke_unit_reader(p_reader varchar, p_role varchar)
  returns varchar
  language sql
  execute as owner
as
$$
declare
  c_db       varchar default 'silver';
  v_db_role  varchar;
  v_role     varchar;
begin
  v_role := upper(p_role);
  if (v_role is null or not regexp_like(v_role, '[A-Z][A-Z0-9_]{0,200}') or startswith(v_role, 'SVC_')) then
    return 'REFUSED:invalid_role';
  end if;
  if (p_reader = c_db) then
    v_db_role := c_db || '.reader';
  elseif (regexp_like(p_reader, 'silver[.][a-z][a-z0-9_]{0,40}') and not contains(p_reader, '__')) then
    v_db_role := c_db || '.reader_' || split_part(p_reader, '.', 2);
  else
    return 'REFUSED:invalid_reader';
  end if;

  execute immediate 'revoke database role ' || v_db_role || ' from role ' || v_role;
  call analytics_ops.control.log_event(:p_reader, 'ACCESS_REVOKED', null::timestamp_ntz, null::varchar,
    object_construct('reader', :v_db_role, 'role', :v_role));
  return 'REVOKED:' || v_db_role || ' from ' || v_role;
end;
$$;

grant usage on procedure silver.ops.onboard_unit(varchar)                to role silver_operator;
grant usage on procedure silver.ops.offboard_unit(varchar)               to role silver_operator;
grant usage on procedure silver.ops.grant_unit_reader(varchar, varchar)  to role silver_operator;
grant usage on procedure silver.ops.revoke_unit_reader(varchar, varchar) to role silver_operator;

show procedures in schema silver.ops;
