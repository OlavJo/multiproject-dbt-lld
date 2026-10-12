-- =============================================================================
-- Prototype / Increment 2 / Step 20: run-control status and the unit lease
--
-- The run-control objects publication needs, as validated in spikes S12 and P3 (SLD 12):
--   v_landing_complete    the platform's landing records, as read by analytics (SLD 4.1)
--   unit_status           last PUBLISHED, watermark, last event per unit; raw units appear
--                         as PUBLISHED from their landing records (SLD 12.6)
--   unit_has_new_input    gate condition 2: deployed or an upstream published since the
--                         unit's last publication (SLD 12.5)
--   acquire_lease, release_lease
--                         the unit lease (SLD 12.4; S12), owner's rights
--
-- Grants go to SILVER_UNIT_BASE (every unit role) and SILVER_OPERATOR, never to a unit
-- role directly (LLD 01, 7.1.1 step 3).
--
-- Run as: SILVER_STEWARD. Requires: i1_30, i1_40, i2_10. Idempotent.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse lld_wh;

create or replace view analytics_ops.control.v_landing_complete as
  select source_system, batch_id, completed_at, detail from raw.control.landing_complete;

create or replace view analytics_ops.control.unit_status as
with events as (
  select unit, event_type, event_ts, watermark from analytics_ops.control.publish_log
  union all
  select 'raw.' || lower(source_system), 'PUBLISHED', completed_at, completed_at
  from analytics_ops.control.v_landing_complete
)
select
  unit,
  max(iff(event_type = 'PUBLISHED', event_ts, null))                as published_at,
  max_by(watermark, iff(event_type = 'PUBLISHED', event_ts, null))  as watermark,
  max(iff(event_type = 'DEPLOYED', event_ts, null))                 as deployed_at,
  max_by(event_type, event_ts)                                      as last_event,
  max(event_ts)                                                     as last_event_at
from events
group by unit;

create or replace view analytics_ops.control.unit_has_new_input as
with s as (select * from analytics_ops.control.unit_status),
upstream as (
  select d.unit, max(s.published_at) as upstream_published_at
  from analytics_ops.control.unit_dependencies d
  join s on s.unit = d.upstream_unit
  group by d.unit
)
select
  u.unit, s.published_at, s.deployed_at, up.upstream_published_at,
  coalesce(s.deployed_at > coalesce(s.published_at, '1970-01-01'::timestamp_ntz), false)
  or coalesce(up.upstream_published_at > coalesce(s.published_at, '1970-01-01'::timestamp_ntz), false)
    as has_new_input
from analytics_ops.control.units u
left join s on s.unit = u.unit
left join upstream up on up.unit = u.unit;

-- The lease: at most one run of a unit at a time; expires after max_runtime_minutes (S12)
create or replace procedure analytics_ops.control.acquire_lease(p_unit varchar, p_run_id varchar)
  returns boolean
  language sql
  execute as owner
as
$$
declare
  n integer default 0;
begin
  begin transaction;
  update analytics_ops.control.unit_lease l
     set run_id     = :p_run_id,
         expires_at = dateadd(minute, u.max_runtime_minutes, sysdate())
    from analytics_ops.control.units u
   where l.unit = :p_unit
     and u.unit = l.unit
     and (l.run_id is null or l.expires_at < sysdate());
  n := sqlrowcount;
  commit;
  return n = 1;
exception
  when other then
    rollback;
    raise;
end;
$$;

create or replace procedure analytics_ops.control.release_lease(p_unit varchar, p_run_id varchar)
  returns boolean
  language sql
  execute as owner
as
$$
declare
  n integer default 0;
begin
  update analytics_ops.control.unit_lease
     set run_id = null, expires_at = null
   where unit = :p_unit and run_id = :p_run_id;
  n := sqlrowcount;
  return n = 1;
end;
$$;

grant select on view analytics_ops.control.v_landing_complete to role silver_unit_base;
grant select on view analytics_ops.control.unit_status        to role silver_unit_base;
grant select on view analytics_ops.control.unit_has_new_input to role silver_unit_base;
grant usage on procedure analytics_ops.control.acquire_lease(varchar, varchar) to role silver_unit_base;
grant usage on procedure analytics_ops.control.release_lease(varchar, varchar) to role silver_unit_base;

grant select on view analytics_ops.control.v_landing_complete to role silver_operator;
grant select on view analytics_ops.control.unit_status        to role silver_operator;
grant select on view analytics_ops.control.unit_has_new_input to role silver_operator;

show views in schema analytics_ops.control;
show procedures in schema analytics_ops.control;
