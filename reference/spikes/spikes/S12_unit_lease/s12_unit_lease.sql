-- =============================================================================
-- Spike S12: Unit lease, stale STARTED detection, and the DEPLOYED trigger
-- See README.md in this folder for the question, method and result.
--
-- Builds a first cut of the run-control objects in ANALYTICS_OPS.CONTROL
-- (SLD 12.2 to 12.7), owned by SILVER_STEWARD, and tests them:
--   Part A  lease acquire / release semantics                  (SVC_SILVER_ERP)
--   Part B  lease expiry and takeover of a dead run's lease    (SVC_SILVER_ERP)
--   Part C  privilege boundaries                               (SVC, ANALYST)
--   Part D  concurrent acquisition: 5 races x 20 contenders    (SVC_SILVER_ERP)
--   Part E  stale STARTED detection                            (SILVER_STEWARD)
--   Part F  "something new to build" gate incl. DEPLOYED       (SILVER_STEWARD)
--
-- Idempotent: recreates ANALYTICS_OPS.CONTROL. Spike data only.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- =============================================================================
-- Setup 1: run-control objects (steward)
-- =============================================================================
use role silver_steward;

create or replace schema analytics_ops.control with managed access;

-- One row per publication unit (SLD 12.3; columns limited to what S12 needs)
create table analytics_ops.control.units (
  unit                varchar,
  tier                varchar,
  max_runtime_minutes integer
);

-- One row per dependency edge (SLD 12.3)
create table analytics_ops.control.unit_dependencies (
  unit          varchar,
  upstream_unit varchar,
  max_age_hours integer
);

-- Append-only event log (SLD 12.2)
create table analytics_ops.control.publish_log (
  event_ts    timestamp_ntz default sysdate(),
  unit        varchar,
  event_type  varchar,
  watermark   timestamp_ntz,
  run_id      varchar,
  detail      variant
);

-- The lease: the one mutable table (SLD 12.4)
create table analytics_ops.control.unit_lease (
  unit        varchar,
  run_id      varchar,
  expires_at  timestamp_ntz
);

insert into analytics_ops.control.units values
  ('test.lease',    'T0', 30),
  ('test.expiring', 'T0', 0),    -- lease expires immediately: simulates a dead run
  ('test.race',     'T0', 30),
  ('test.dead',     'T0', 30),
  ('test.running',  'T0', 30),
  ('test.done',     'T0', 30),
  ('test.silver',   'T0', 30),
  ('test.tier1',    'T1', 30);

insert into analytics_ops.control.unit_lease (unit)
  select unit from analytics_ops.control.units;

insert into analytics_ops.control.unit_dependencies values
  ('test.tier1', 'test.silver', 24);

-- Acquire: one conditional UPDATE inside a transaction; success iff one row
-- updated (SLD 12.4). Owner's rights: callers need no privileges on the table.
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

-- Release: only the holder's run_id can release
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
   where unit = :p_unit
     and run_id = :p_run_id;
  n := sqlrowcount;
  return n = 1;
end;
$$;

-- Current state derived from the log (SLD 12.6, without the landing union)
create or replace view analytics_ops.control.unit_status as
select
  unit,
  max(iff(event_type = 'PUBLISHED', event_ts, null))               as published_at,
  max_by(watermark, iff(event_type = 'PUBLISHED', event_ts, null)) as watermark,
  max(iff(event_type = 'DEPLOYED', event_ts, null))                as deployed_at,
  max_by(event_type, event_ts)                                     as last_event,
  max(event_ts)                                                    as last_event_at
from analytics_ops.control.publish_log
group by unit;

-- Stale STARTED: a run that died without a terminal event (SLD 12.6)
create or replace view analytics_ops.control.unit_stale as
select
  s.unit, s.last_event, s.last_event_at, u.max_runtime_minutes,
  (s.last_event = 'STARTED'
   and s.last_event_at < dateadd(minute, -u.max_runtime_minutes, sysdate())) as is_stale
from analytics_ops.control.unit_status s
join analytics_ops.control.units u on u.unit = s.unit;

-- Gate condition 2: something new to build since this unit last published
-- (an upstream PUBLISHED, or this unit's own DEPLOYED) (SLD 12.7)
create or replace view analytics_ops.control.unit_has_new_input as
with last_pub as (
  select u.unit, max(iff(l.event_type = 'PUBLISHED', l.event_ts, null)) as published_at
  from analytics_ops.control.units u
  left join analytics_ops.control.publish_log l on l.unit = u.unit
  group by u.unit
),
deployed as (
  select unit, max(event_ts) as deployed_at
  from analytics_ops.control.publish_log
  where event_type = 'DEPLOYED'
  group by unit
),
upstream as (
  select d.unit, max(l.event_ts) as upstream_published_at
  from analytics_ops.control.unit_dependencies d
  join analytics_ops.control.publish_log l
    on l.unit = d.upstream_unit and l.event_type = 'PUBLISHED'
  group by d.unit
)
select
  p.unit, p.published_at, dp.deployed_at, up.upstream_published_at,
  coalesce(dp.deployed_at > coalesce(p.published_at, '1970-01-01'::timestamp_ntz), false)
  or coalesce(up.upstream_published_at > coalesce(p.published_at, '1970-01-01'::timestamp_ntz), false)
    as has_new_input
from last_pub p
left join deployed dp on dp.unit = p.unit
left join upstream up on up.unit = p.unit;

-- Unit service role: may call the lease procedures and read the lease; nothing else
grant usage on database analytics_ops                       to role svc_silver_erp;
grant usage on schema analytics_ops.control                 to role svc_silver_erp;
grant usage on procedure analytics_ops.control.acquire_lease(varchar, varchar) to role svc_silver_erp;
grant usage on procedure analytics_ops.control.release_lease(varchar, varchar) to role svc_silver_erp;
grant select on table analytics_ops.control.unit_lease      to role svc_silver_erp;

-- =============================================================================
-- Setup 2: race harness (spike scaffolding, SYSADMIN owns SPIKE_LAB.EVIDENCE)
-- =============================================================================
use role sysadmin;

create table if not exists spike_lab.evidence.lease_race (
  race_id      varchar,
  run_id       varchar,
  acquired     boolean,
  attempted_at timestamp_ntz
);
create table if not exists spike_lab.evidence.lease_race_holder (
  race_id varchar,
  holder  varchar
);

-- One contender: the publish procedure's step 0 (acquire, then record outcome).
-- Each contender generates its own run id, so nothing depends on how ASYNC binds
-- loop variables.
create or replace procedure spike_lab.evidence.race_one(p_race_id varchar, p_unit varchar)
  returns boolean
  language sql
  execute as caller
as
$$
declare
  ok  boolean default false;
  rid varchar;
begin
  rid := p_race_id || '-' || uuid_string();
  call analytics_ops.control.acquire_lease(:p_unit, :rid) into :ok;
  insert into spike_lab.evidence.lease_race (race_id, run_id, acquired, attempted_at)
    values (:p_race_id, :rid, :ok, sysdate());
  return ok;
end;
$$;

-- One race: N contenders as concurrent asynchronous child jobs; then record the
-- holder and release the lease so the next race starts from a free lease
create or replace procedure spike_lab.evidence.race_lease(p_race_id varchar, p_unit varchar, p_contenders integer)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  holder varchar;
begin
  for i in 1 to p_contenders do
    async (call spike_lab.evidence.race_one(:p_race_id, :p_unit));
  end for;
  await all;
  select run_id into :holder from analytics_ops.control.unit_lease where unit = :p_unit;
  insert into spike_lab.evidence.lease_race_holder (race_id, holder) values (:p_race_id, :holder);
  call analytics_ops.control.release_lease(:p_unit, :holder);
  return holder;
end;
$$;

grant select, insert on table spike_lab.evidence.lease_race        to role svc_silver_erp;
grant select, insert on table spike_lab.evidence.lease_race_holder to role svc_silver_erp;
grant usage on procedure spike_lab.evidence.race_one(varchar, varchar)             to role svc_silver_erp;
grant usage on procedure spike_lab.evidence.race_lease(varchar, varchar, integer)  to role svc_silver_erp;

-- =============================================================================
-- Part A: acquire / release semantics
-- =============================================================================
use role svc_silver_erp;
set r1 = (select $run_id || '-r1');
set r2 = (select $run_id || '-r2');

call spike_lab.evidence.probe($run_id, 'S12', 'S12.01', 'A: acquire a free lease',
  'call analytics_ops.control.acquire_lease(''test.lease'', ''' || $r1 || ''')', 'true');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.02', 'A: a second run cannot acquire a held lease',
  'call analytics_ops.control.acquire_lease(''test.lease'', ''' || $r2 || ''')', 'false');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.03', 'A: a run that does not hold the lease cannot release it',
  'call analytics_ops.control.release_lease(''test.lease'', ''' || $r2 || ''')', 'false');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.04', 'A: lease still held by the first run',
  $$select run_id from analytics_ops.control.unit_lease where unit = 'test.lease'$$, '%-r1');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.05', 'A: the holder releases its lease',
  'call analytics_ops.control.release_lease(''test.lease'', ''' || $r1 || ''')', 'true');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.06', 'A: a released lease can be acquired',
  'call analytics_ops.control.acquire_lease(''test.lease'', ''' || $r2 || ''')', 'true');
call analytics_ops.control.release_lease('test.lease', $r2);

-- =============================================================================
-- Part B: expiry (unit test.expiring has max_runtime_minutes = 0)
-- =============================================================================
set d1 = (select $run_id || '-d1');
set d2 = (select $run_id || '-d2');

call spike_lab.evidence.probe($run_id, 'S12', 'S12.10', 'B: a run acquires the lease and then "dies" (never releases)',
  'call analytics_ops.control.acquire_lease(''test.expiring'', ''' || $d1 || ''')', 'true');
select system$wait(2);
call spike_lab.evidence.probe($run_id, 'S12', 'S12.11', 'B: after expiry, a new run takes over the lease',
  'call analytics_ops.control.acquire_lease(''test.expiring'', ''' || $d2 || ''')', 'true');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.12', 'B: the dead run, if it wakes, cannot release the new holder''s lease',
  'call analytics_ops.control.release_lease(''test.expiring'', ''' || $d1 || ''')', 'false');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.13', 'B: the lease is held by the new run',
  $$select run_id from analytics_ops.control.unit_lease where unit = 'test.expiring'$$, '%-d2');

-- =============================================================================
-- Part C: privilege boundaries
-- =============================================================================
call spike_lab.evidence.probe($run_id, 'S12', 'S12.20', 'C: unit service role cannot update the lease table directly',
  $$update analytics_ops.control.unit_lease set run_id = 'hijack' where unit = 'test.lease'$$, 'ERROR:%');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.21', 'C: unit service role cannot write the event log directly',
  $$insert into analytics_ops.control.publish_log (unit, event_type) values ('test.lease', 'PUBLISHED')$$, 'ERROR:%');

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S12', 'S12.22', 'C: a consumer cannot call the lease procedures',
  $$call analytics_ops.control.acquire_lease('test.lease', 'consumer')$$, 'ERROR:%');

-- =============================================================================
-- Part D: concurrent acquisition. 5 races, 20 concurrent contenders each.
-- Every race must have exactly one winner, and the winner must be the holder.
-- =============================================================================
use role svc_silver_erp;

call spike_lab.evidence.race_lease($run_id || '-race1', 'test.race', 20);
call spike_lab.evidence.race_lease($run_id || '-race2', 'test.race', 20);
call spike_lab.evidence.race_lease($run_id || '-race3', 'test.race', 20);
call spike_lab.evidence.race_lease($run_id || '-race4', 'test.race', 20);
call spike_lab.evidence.race_lease($run_id || '-race5', 'test.race', 20);

call spike_lab.evidence.probe($run_id, 'S12', 'S12.30', 'D: all 100 contenders completed with distinct run ids',
  'select count(distinct run_id) from spike_lab.evidence.lease_race where race_id like ''' || $run_id || '-race%''', '100');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.31', 'D: contenders overlapped in time (attempt timestamps per race span, max seconds)',
  'select max(datediff(millisecond, mn, mx)) / 1000 from (select race_id, min(attempted_at) mn, max(attempted_at) mx from spike_lab.evidence.lease_race where race_id like ''' || $run_id || '-race%'' group by race_id)', null);
call spike_lab.evidence.probe($run_id, 'S12', 'S12.32', 'KEY D: number of races without exactly one winner',
  'select count(*) from (select race_id, count_if(acquired) w from spike_lab.evidence.lease_race where race_id like ''' || $run_id || '-race%'' group by race_id) where w <> 1', '0');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.33', 'D: number of races where the recorded winner is not the lease holder',
  'select count(*) from spike_lab.evidence.lease_race_holder h left join spike_lab.evidence.lease_race r on r.race_id = h.race_id and r.run_id = h.holder and r.acquired where h.race_id like ''' || $run_id || '-race%'' and r.run_id is null', '0');

-- =============================================================================
-- Part E: stale STARTED detection (events with explicit timestamps)
-- =============================================================================
use role silver_steward;
insert into analytics_ops.control.publish_log (event_ts, unit, event_type, run_id) values
  (dateadd(minute, -120, sysdate()), 'test.dead',    'STARTED',   'e1'),
  (dateadd(minute,   -5, sysdate()), 'test.running', 'STARTED',   'e2'),
  (dateadd(minute, -120, sysdate()), 'test.done',    'STARTED',   'e3'),
  (dateadd(minute, -100, sysdate()), 'test.done',    'PUBLISHED', 'e3');

call spike_lab.evidence.probe($run_id, 'S12', 'S12.40', 'E: STARTED 120 min ago, max runtime 30, no terminal event: stale',
  $$select is_stale from analytics_ops.control.unit_stale where unit = 'test.dead'$$, 'true');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.41', 'E: STARTED 5 min ago: not stale',
  $$select is_stale from analytics_ops.control.unit_stale where unit = 'test.running'$$, 'false');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.42', 'E: STARTED then PUBLISHED: not stale',
  $$select is_stale from analytics_ops.control.unit_stale where unit = 'test.done'$$, 'false');

-- =============================================================================
-- Part F: gate condition "something new to build" (SLD 12.7)
-- test.tier1 depends on test.silver. Events are added step by step.
-- =============================================================================
insert into analytics_ops.control.publish_log (event_ts, unit, event_type, watermark) values
  (dateadd(minute, -120, sysdate()), 'test.silver', 'PUBLISHED', dateadd(minute, -125, sysdate())),
  (dateadd(minute,  -60, sysdate()), 'test.tier1',  'PUBLISHED', dateadd(minute, -125, sysdate()));
call spike_lab.evidence.probe($run_id, 'S12', 'S12.50', 'F: nothing new since tier1 last published: gate skips',
  $$select has_new_input from analytics_ops.control.unit_has_new_input where unit = 'test.tier1'$$, 'false');

insert into analytics_ops.control.publish_log (event_ts, unit, event_type, detail)
  select dateadd(minute, -30, sysdate()), 'test.tier1', 'DEPLOYED', object_construct('commit', 'abc123');
call spike_lab.evidence.probe($run_id, 'S12', 'S12.51', 'KEY F: a DEPLOYED event after the last publication: gate proceeds',
  $$select has_new_input from analytics_ops.control.unit_has_new_input where unit = 'test.tier1'$$, 'true');

insert into analytics_ops.control.publish_log (event_ts, unit, event_type, watermark) values
  (dateadd(minute, -20, sysdate()), 'test.tier1', 'PUBLISHED', dateadd(minute, -125, sysdate()));
call spike_lab.evidence.probe($run_id, 'S12', 'S12.52', 'F: after publishing the deployed code: gate skips',
  $$select has_new_input from analytics_ops.control.unit_has_new_input where unit = 'test.tier1'$$, 'false');

insert into analytics_ops.control.publish_log (event_ts, unit, event_type, watermark) values
  (dateadd(minute, -10, sysdate()), 'test.silver', 'PUBLISHED', dateadd(minute, -15, sysdate()));
call spike_lab.evidence.probe($run_id, 'S12', 'S12.53', 'F: an upstream PUBLISHED after the last publication: gate proceeds',
  $$select has_new_input from analytics_ops.control.unit_has_new_input where unit = 'test.tier1'$$, 'true');

call spike_lab.evidence.probe($run_id, 'S12', 'S12.54', 'F: unit_status derives the latest watermark from the log',
  $$select to_varchar(watermark > dateadd(minute, -20, sysdate())) from analytics_ops.control.unit_status where unit = 'test.silver'$$, 'true');

-- Evidence ---------------------------------------------------------------------
select case_id, outcome, description, observed, expected, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Export as evidence/S12_<yyyymmdd>.csv
