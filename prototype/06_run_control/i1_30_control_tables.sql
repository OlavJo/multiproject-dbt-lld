-- =============================================================================
-- Prototype / Increment 1 / Step 30: run-control tables (baseline)
--
-- The run-control objects of SLD 12 that onboarding needs, as validated in S12:
--   units, unit_dependencies   configuration (SLD 12.3); `sensitive` added (LLD 01, 7.3)
--   publish_log                append-only event log (SLD 12.2)
--   unit_lease                 the unit lease table (SLD 12.4); lease procedures in Increment 2
--   log_event                  owner's-rights writer: the only way into the log (S12)
--
-- Event types used from this increment, in addition to SLD 12.2:
--   ONBOARDED, OFFBOARDED       a unit's roles and schema created or retired
--   ACCESS_GRANTED, ACCESS_REVOKED   a reader role granted to or revoked from a consumer role
--
-- Run as: SILVER_STEWARD. Requires: i1_10. Idempotent; the tables are created
-- if missing, never replaced, so configuration and the log survive a rerun.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse spike_wh;

create schema if not exists analytics_ops.control with managed access;

create table if not exists analytics_ops.control.units (
  unit                varchar not null,      -- 'silver.erp', 'raw.erp'
  tier                varchar not null,      -- RAW | T0 | T0.5 | T1 | T2
  owner               varchar,               -- owning team
  sensitive           boolean default false, -- reader role kept out of the aggregate reader (LLD 01, 7.3)
  selector            varchar,
  dbt_target          varchar,
  max_runtime_minutes integer default 30
);

create table if not exists analytics_ops.control.unit_dependencies (
  unit          varchar not null,
  upstream_unit varchar not null,
  max_age_hours integer
);

create table if not exists analytics_ops.control.publish_log (
  event_ts    timestamp_ntz default sysdate(),   -- UTC
  unit        varchar,
  event_type  varchar,
  watermark   timestamp_ntz,
  run_id      varchar,
  detail      variant
);

create table if not exists analytics_ops.control.unit_lease (
  unit        varchar,
  run_id      varchar,
  expires_at  timestamp_ntz
);

create or replace procedure analytics_ops.control.log_event(
    p_unit varchar, p_event varchar, p_watermark timestamp_ntz, p_run_id varchar, p_detail variant)
  returns varchar
  language sql
  execute as owner
as
$$
begin
  insert into analytics_ops.control.publish_log (unit, event_type, watermark, run_id, detail)
    select :p_unit, :p_event, :p_watermark, :p_run_id, :p_detail;
  return 'ok';
end;
$$;

show tables in schema analytics_ops.control;
