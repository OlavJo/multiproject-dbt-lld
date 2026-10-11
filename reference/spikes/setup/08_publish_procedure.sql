-- =============================================================================
-- Phase 2 / Step 08: the publish procedure (SLD 10.4)
--
--   silver.ops.publish_unit(p_unit)   caller's rights; one generic procedure per unit
--
-- Steps: lease, gate (upstream freshness, something new to build), STARTED, clone
-- the published schema, freeze (run-operation), build (selector), grant/swap/revoke
-- (S2), canonical compile for CI (SLD 3.2), PUBLISHED, release the lease. Every
-- EXECUTE DBT PROJECT result is read and checked (S3). A failure logs FAILED with
-- the stage, exception and the tail of STDOUT, never publishes, and always releases
-- the lease.
--
-- Returns a short status string: PUBLISHED, SKIPPED:<reason>, FAILED:<stage>.
--
-- Also here:
--   analytics_ops.control.log_event(...)   owner's-rights log writer (SLD 12.2: unit
--                                          roles may not insert into the log directly)
--   unit_has_new_input                      rewritten to include raw units' landing records
--
-- Requires setup/06 and 07. Run as: SILVER_STEWARD. Idempotent.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse spike_wh;

-- Log writer: the only way a unit role can append to the log ------------------------
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

-- Gate condition 2 with raw units' landing records as PUBLISHED events (SLD 12.5, 12.7)
create or replace view analytics_ops.control.unit_has_new_input as
with events as (
  select unit, event_type, event_ts from analytics_ops.control.publish_log
  union all
  select 'raw.' || lower(source_system), 'PUBLISHED', completed_at from analytics_ops.control.v_landing_complete
),
last_pub as (
  select u.unit, max(iff(e.event_type = 'PUBLISHED', e.event_ts, null)) as published_at
  from analytics_ops.control.units u
  left join events e on e.unit = u.unit
  group by u.unit
),
deployed as (
  select unit, max(event_ts) as deployed_at from events where event_type = 'DEPLOYED' group by unit
),
upstream as (
  select d.unit, max(e.event_ts) as upstream_published_at
  from analytics_ops.control.unit_dependencies d
  join events e on e.unit = d.upstream_unit and e.event_type = 'PUBLISHED'
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

-- Drops the input clones of a unit (best effort; the next run replaces them anyway) ----------
create or replace procedure silver.ops.drop_input_clones(p_unit varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  v_schema varchar;
  v_sql    varchar;
begin
  v_schema := split_part(p_unit, '.', 2);
  let c_up cursor for
    select split_part(upstream_unit, '.', 2) as up
    from analytics_ops.control.unit_dependencies
    where unit = ? and upstream_unit like 'silver.%';
  open c_up using (p_unit);
  for r_up in c_up do
    begin
      v_sql := 'drop schema if exists silver.' || v_schema || '__in_' || r_up.up;
      execute immediate :v_sql;
    exception when other then null;
    end;
  end for;
  return 'ok';
end;
$$;

-- The publish procedure ---------------------------------------------------------------
create or replace procedure silver.ops.publish_unit(p_unit varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  failed      exception (-20001, 'publish step failed');
  v_run_id    varchar default uuid_string();
  v_schema    varchar;
  v_build     varchar;
  v_selector  varchar;
  v_target    varchar;
  v_leased    boolean default false;
  v_released  boolean;
  v_granted   boolean default false;
  v_stale     integer default 0;
  v_new       boolean default false;
  v_wm        timestamp_ntz;
  v_wm_txt    varchar;
  v_sql       varchar;
  v_ok        boolean;
  v_exc       varchar;
  v_out       varchar;
  v_stage     varchar default 'init';
  v_class     varchar default 'unclassified';
  v_state_qid varchar;
  v_canon_ok  boolean default false;
  v_canon_err varchar;
  v_fail_qid  varchar;
  v_log_ok    boolean default false;
  v_raw_up    integer default 0;
  v_inputs    varchar default '';
  v_clone_ts  timestamp_ntz;
begin
  select selector, dbt_target into :v_selector, :v_target
    from analytics_ops.control.units where unit = :p_unit;
  if (v_selector is null) then
    return 'FAILED:unknown_unit';
  end if;
  v_schema := split_part(p_unit, '.', 2);
  v_build  := v_schema || '__build';

  -- 0. Lease
  call analytics_ops.control.acquire_lease(:p_unit, :v_run_id) into :v_leased;
  if (not v_leased) then
    call analytics_ops.control.log_event(:p_unit, 'SKIPPED', null::timestamp_ntz, :v_run_id, object_construct('reason', 'locked'));
    return 'SKIPPED:locked';
  end if;

  begin
    -- 1. Gate: every upstream watermark within its tolerance, and something new to build
    v_stage := 'gate';
    select count(*) into :v_stale
      from analytics_ops.control.unit_dependencies d
      left join analytics_ops.control.unit_status s on s.unit = d.upstream_unit
      where d.unit = :p_unit
        and (s.watermark is null or s.watermark < dateadd(hour, -d.max_age_hours, sysdate()));
    if (v_stale > 0) then
      call analytics_ops.control.log_event(:p_unit, 'SKIPPED', null::timestamp_ntz, :v_run_id, object_construct('reason', 'stale_upstream', 'stale_edges', :v_stale));
      call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
      return 'SKIPPED:stale_upstream';
    end if;
    select has_new_input into :v_new from analytics_ops.control.unit_has_new_input where unit = :p_unit;
    if (v_new is null or not v_new) then
      call analytics_ops.control.log_event(:p_unit, 'SKIPPED', null::timestamp_ntz, :v_run_id, object_construct('reason', 'nothing_new'));
      call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
      return 'SKIPPED:nothing_new';
    end if;
    -- Unit watermark: the minimum of its upstream watermarks, read now (SLD 11.2)
    select min(s.watermark) into :v_wm
      from analytics_ops.control.unit_dependencies d
      join analytics_ops.control.unit_status s on s.unit = d.upstream_unit
      where d.unit = :p_unit;
    v_wm_txt := to_varchar(v_wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3');

    -- 2. STARTED, then a managed-access clone of the last good state (S2)
    call analytics_ops.control.log_event(:p_unit, 'STARTED', :v_wm, :v_run_id, object_construct('selector', :v_selector, 'target', :v_target));
    v_stage := 'clone';
    v_sql := 'create or replace schema silver.' || v_build || ' clone silver.' || v_schema || ' with managed access';
    execute immediate :v_sql;

    -- 2b. Input clones (SLD 10.9, S10): a unit that reads other Silver units' published schemas
    -- reads zero-copy clones of them taken now, so a swap upstream during the build cannot split
    -- its reads between two versions. The unit's models resolve those references to
    -- <unit>__in_<upstream> (macros/unit_schemas.sql, var input_clones).
    v_stage := 'input_clones';
    let c_up cursor for
      select split_part(upstream_unit, '.', 2) as up
      from analytics_ops.control.unit_dependencies
      where unit = ? and upstream_unit like 'silver.%';
    open c_up using (p_unit);
    for r_up in c_up do
      v_sql := 'create or replace schema silver.' || v_schema || '__in_' || r_up.up || ' clone silver.' || r_up.up;
      execute immediate :v_sql;
      v_inputs := v_inputs || iff(v_inputs = '', '', ',') || (v_schema || '__in_' || r_up.up);
    end for;
    v_clone_ts := sysdate();

    -- 3. Freeze at the watermark (S3: the result is read, not assumed). Only a unit with raw
    -- upstreams freezes; the Core module reads published Silver outputs and never raw (SLD 7.2).
    select count(*) into :v_raw_up from analytics_ops.control.unit_dependencies
      where unit = :p_unit and upstream_unit like 'raw.%';
    if (v_raw_up > 0) then
      v_stage := 'freeze';
      v_class := 'unclassified';
      v_sql := 'execute dbt project silver.ops.silver_layer args = ''run-operation freeze_sources'
        || ' --args "{unit: ' || v_schema || ', watermark: ' || v_wm_txt || '}"'
        || ' --vars "{publish_unit: ' || v_schema || '}" --target ' || v_target
        || ' --target-path target/' || v_schema || ' --log-path logs/' || v_schema || '''';
      execute immediate :v_sql;
      select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
        from table(result_scan(last_query_id()));
      if (v_ok is null or not v_ok) then
        raise failed;
      end if;
    end if;

    -- 4. Source tests, build, output tests: one dbt build
    v_stage := 'build';
    v_class := 'unclassified';
    v_sql := 'execute dbt project silver.ops.silver_layer args = ''build --selector ' || v_selector
      || ' --vars "{publish_unit: ' || v_schema || '}" --target ' || v_target
      || ' --target-path target/' || v_schema || ' --log-path logs/' || v_schema || '''';
    execute immediate :v_sql;
    select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
      from table(result_scan(last_query_id()));
    if (v_ok is null or not v_ok) then
      raise failed;
    end if;

    -- 5. Atomic publish with the S2 grant sequence
    v_stage := 'publish';
    v_sql := 'grant usage on schema silver.' || v_build || ' to database role silver.reader';
    execute immediate :v_sql;
    v_granted := true;
    v_sql := 'alter schema silver.' || v_build || ' swap with silver.' || v_schema;
    execute immediate :v_sql;
    v_sql := 'revoke usage on schema silver.' || v_build || ' from database role silver.reader';
    execute immediate :v_sql;
    v_granted := false;
    call silver.ops.drop_input_clones(:p_unit);

    -- 6. Canonical state for CI (SLD 3.2). A failure here does not affect consumers.
    v_stage := 'canonical';
    begin
      v_sql := 'execute dbt project silver.ops.silver_layer args = ''compile --target ' || v_target
        || ' --target-path target/canonical --log-path logs/canonical'' writeback = false';
      execute immediate :v_sql;
      select last_query_id() into :v_state_qid;
      select $1::boolean into :v_canon_ok from table(result_scan(:v_state_qid));
    exception
      when other then
        v_canon_ok := false;
        v_canon_err := sqlerrm;
    end;

    -- 7. PUBLISHED and release
    call analytics_ops.control.log_event(:p_unit, 'PUBLISHED', :v_wm, :v_run_id,
      object_construct('state_query_id', :v_state_qid, 'canonical_ok', :v_canon_ok, 'canonical_error', :v_canon_err,
                       'input_clones', :v_inputs, 'inputs_cloned_at', :v_clone_ts));
    call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
    return 'PUBLISHED';

  exception
    when failed then
      if (v_granted) then
        begin
          v_sql := 'revoke usage on schema silver.' || v_build || ' from database role silver.reader';
          execute immediate :v_sql;
        exception when other then null;
        end;
      end if;
      call silver.ops.drop_input_clones(:p_unit);
      call analytics_ops.control.log_event(:p_unit, 'FAILED', :v_wm, :v_run_id,
        object_construct('stage', :v_stage, 'failure_class', :v_class, 'exception', :v_exc,
                         'stdout_tail', right(coalesce(:v_out, ''), 3000)));
      call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
      return 'FAILED:' || v_stage;
    when other then
      -- EXECUTE DBT PROJECT RAISES on a dbt failure on this runtime (S3): the error
      -- text carries dbt's output and a query id for SYSTEM$GET_DBT_LOG.
      v_exc := sqlerrm;
      if (v_granted) then
        begin
          v_sql := 'revoke usage on schema silver.' || v_build || ' from database role silver.reader';
          execute immediate :v_sql;
        exception when other then null;
        end;
      end if;
      begin
        v_fail_qid := regexp_substr(:v_exc, 'system[$]get_dbt_log[(]''([^'']+)''[)]', 1, 1, 'e', 1);
        if (v_fail_qid is not null) then
          select system$get_dbt_log(:v_fail_qid) into :v_out;
          v_log_ok := true;
        end if;
      exception when other then null;
      end;
      -- Attribute from where the failure sits (SLD 4.3, 8): a source test, or the
      -- freeze, is ingestion's; any other test or model failure is the stewards'.
      -- A freeze failure is ingestion's only if it names a raw object or Time Travel on one
      -- (a missing table, no history at the watermark); a privilege or schema problem is the stewards'.
      if (contains(v_exc, 'in test source_')
          or (v_stage = 'freeze' and (contains(v_exc, '''RAW.') or contains(v_exc, 'ime travel')))) then
        v_class := 'source';
      elseif (contains(v_exc, 'in test ') or contains(v_exc, 'in model ')) then
        v_class := 'transform';
      end if;
      call silver.ops.drop_input_clones(:p_unit);
      call analytics_ops.control.log_event(:p_unit, 'FAILED', :v_wm, :v_run_id,
        object_construct('stage', :v_stage, 'failure_class', :v_class, 'exception', left(:v_exc, 4000),
                         'dbt_query_id', :v_fail_qid, 'dbt_log_fetched', :v_log_ok,
                         'stdout_tail', right(coalesce(:v_out, ''), 3000)));
      call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
      return 'FAILED:' || v_stage;
  end;
end;
$$;

-- Grants -------------------------------------------------------------------------------
grant usage on procedure silver.ops.publish_unit(varchar) to role svc_silver_erp;
grant usage on procedure silver.ops.publish_unit(varchar) to role svc_silver_crm;
grant usage on procedure silver.ops.drop_input_clones(varchar) to role svc_silver_erp;
grant usage on procedure silver.ops.drop_input_clones(varchar) to role svc_silver_crm;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role svc_silver_erp;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role svc_silver_crm;
grant select on view  analytics_ops.control.unit_has_new_input to role svc_silver_erp;
grant select on view  analytics_ops.control.unit_has_new_input to role svc_silver_crm;
grant select on table analytics_ops.control.unit_dependencies  to role svc_silver_erp;
grant select on table analytics_ops.control.unit_dependencies  to role svc_silver_crm;
grant select on table analytics_ops.control.units              to role svc_silver_erp;
grant select on table analytics_ops.control.units              to role svc_silver_crm;
grant select on table analytics_ops.control.publish_log        to role svc_silver_erp;
grant select on table analytics_ops.control.publish_log        to role svc_silver_crm;

show procedures like 'PUBLISH_UNIT' in schema silver.ops;
