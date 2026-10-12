-- =============================================================================
-- Prototype / Increment 2 / Step 40: the publish procedure (SLD 10.4)
--
--   silver.ops.publish_unit(p_unit)   caller's rights; one generic procedure for every
--                                     Silver unit, run by the unit's own role (its task)
--
-- Sequence (validated in spikes P3, S2, S3, S12): lease; gate (upstream watermarks within
-- tolerance, something new to build); STARTED; clone the published schema into
-- <unit>__build, managed access; freeze at the watermark; dbt build of the unit's
-- selector; grant USAGE on the build schema to the unit's reader role, swap, revoke (F3);
-- canonical compile for CI; PUBLISHED; release the lease. Every dbt result is read. A
-- failure logs FAILED with the stage and dbt's output, never publishes, and always
-- releases the lease.
--
-- Differences from the spike procedure (reference/spikes/setup/08):
--   * the reader role is the unit's own, silver.reader_<unit> (IA-3), not silver.reader;
--     the unit role owns both schemas, so it grants and revokes itself (INC1.42)
--   * names (database, project object, reader prefix) are constants at the top (guardrail 7)
--   * input clones (Increment 3) are taken and dropped by silver.ops.take_input_clones and
--     drop_input_clones, owned by SILVER_SCHEDULER (IA-2 b), not by the unit role: the spike's
--     unit role inherited the upstream unit roles to clone them, which IA-2 rejects
--
-- PB-4 (where the procedure lives for Tier 1 and Tier 2) is open; Silver's lives in
-- silver.ops, owned by SILVER_STEWARD, as in the HLD baseline.
--
-- Returns PUBLISHED, SKIPPED:<reason> or FAILED:<stage>.
-- Run as: SILVER_STEWARD. Requires: i1_40, i2_20, i2_30 (and i3_10 for units with Silver
-- upstreams). Idempotent.
-- =============================================================================

use role silver_steward;
use secondary roles none;
use warehouse lld_wh;

create or replace procedure silver.ops.publish_unit(p_unit varchar)
  returns varchar
  language sql
  execute as caller
as
$$
declare
  c_db        varchar default 'silver';
  c_project   varchar default 'silver.ops.silver_layer';
  c_reader    varchar default 'reader_';         -- reader role: <c_db>.<c_reader><unit>
  failed      exception (-20001, 'publish step failed');
  v_run_id    varchar default uuid_string();
  v_schema    varchar;
  v_build     varchar;
  v_reader    varchar;
  v_selector  varchar;
  v_target    varchar;
  v_leased    boolean default false;
  v_released  boolean;
  v_granted   boolean default false;
  v_stale     integer default 0;
  v_silver_up integer default 0;
  v_raw_up    integer default 0;
  v_new       boolean default false;
  v_wm        timestamp_ntz;
  v_wm_txt    varchar;
  v_dbt_args  varchar;
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
  v_role      varchar;
  v_inputs    varchar default '';
  v_clone_ts  timestamp_ntz;
  v_cloned    boolean default false;
  v_dropped   varchar;
begin
  select current_role() into :v_role;
  select selector, dbt_target into :v_selector, :v_target
    from analytics_ops.control.units where unit = :p_unit;
  if (v_selector is null or v_target is null) then
    return 'FAILED:not_configured';
  end if;
  v_schema   := split_part(p_unit, '.', 2);
  v_build    := v_schema || '__build';
  v_reader   := c_db || '.' || c_reader || v_schema;
  v_dbt_args := ' --vars "{publish_unit: ' || v_schema || '}" --target ' || v_target
             || ' --target-path target/' || v_schema || ' --log-path logs/' || v_schema;

  -- 0. Lease
  call analytics_ops.control.acquire_lease(:p_unit, :v_run_id) into :v_leased;
  if (not v_leased) then
    call analytics_ops.control.log_event(:p_unit, 'SKIPPED', null::timestamp_ntz, :v_run_id, object_construct('reason', 'locked'));
    return 'SKIPPED:locked';
  end if;

  begin
    -- 1. Gate: every upstream watermark within tolerance, and something new to build
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
    select count_if(upstream_unit like 'silver.%'), count_if(upstream_unit like 'raw.%')
      into :v_silver_up, :v_raw_up
      from analytics_ops.control.unit_dependencies where unit = :p_unit;
    -- The unit's watermark: the minimum of its upstream watermarks, read now (SLD 11.2)
    select min(s.watermark) into :v_wm
      from analytics_ops.control.unit_dependencies d
      join analytics_ops.control.unit_status s on s.unit = d.upstream_unit
      where d.unit = :p_unit;
    v_wm_txt := to_varchar(v_wm, 'YYYY-MM-DD"T"HH24:MI:SS.FF3');

    -- 2. STARTED, then a managed-access clone of the last good state (F4)
    call analytics_ops.control.log_event(:p_unit, 'STARTED', :v_wm, :v_run_id,
      object_construct('selector', :v_selector, 'target', :v_target, 'role', :v_role));
    v_stage := 'clone';
    v_sql := 'create or replace schema ' || c_db || '.' || v_build || ' clone ' || c_db || '.' || v_schema || ' with managed access';
    execute immediate :v_sql;

    -- 2b. Input clones (units with Silver upstreams; SLD 10.9, IA-2 b): taken now, by the
    -- scheduler's procedure, and read by the unit's models through var input_clones
    if (v_silver_up > 0) then
      v_stage := 'input_clones';
      call silver.ops.take_input_clones(:p_unit) into :v_inputs;
      v_cloned := true;
      select sysdate() into :v_clone_ts;
      if (v_inputs is null or v_inputs = '' or startswith(v_inputs, 'REFUSED')) then
        v_exc := 'take_input_clones: ' || coalesce(v_inputs, '<null>');
        raise failed;
      end if;
      v_dbt_args := ' --vars "{publish_unit: ' || v_schema || ', input_clones: [' || v_inputs || ']}" --target ' || v_target
                 || ' --target-path target/' || v_schema || ' --log-path logs/' || v_schema;
    end if;

    -- 3. Freeze at the watermark (units with raw upstreams only, SLD 7.2)
    if (v_raw_up > 0) then
      v_stage := 'freeze';
      v_sql := 'execute dbt project ' || c_project || ' args = ''run-operation freeze_sources'
        || ' --args "{unit: ' || v_schema || ', watermark: ' || v_wm_txt || '}"' || v_dbt_args || '''';
      execute immediate :v_sql;
      select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
        from table(result_scan(last_query_id()));
      if (v_ok is null or not v_ok) then
        raise failed;
      end if;
    end if;

    -- 4. Source tests, models, output tests: one dbt build of the unit's selector
    v_stage := 'build';
    v_sql := 'execute dbt project ' || c_project || ' args = ''build --selector ' || v_selector || v_dbt_args || '''';
    execute immediate :v_sql;
    select $1::boolean, $2::varchar, $3::varchar into :v_ok, :v_exc, :v_out
      from table(result_scan(last_query_id()));
    if (v_ok is null or not v_ok) then
      raise failed;
    end if;

    -- 5. Publish: grant, swap, revoke (F3). USAGE moves with the schema in the swap.
    v_stage := 'publish';
    execute immediate 'grant usage on schema ' || c_db || '.' || v_build || ' to database role ' || v_reader;
    v_granted := true;
    execute immediate 'alter schema ' || c_db || '.' || v_build || ' swap with ' || c_db || '.' || v_schema;
    execute immediate 'revoke usage on schema ' || c_db || '.' || v_build || ' from database role ' || v_reader;
    v_granted := false;
    if (v_cloned) then
      call silver.ops.drop_input_clones(:p_unit) into :v_dropped;
    end if;

    -- 6. Canonical state for CI (SLD 3.2); a failure here does not affect consumers
    v_stage := 'canonical';
    begin
      execute immediate 'execute dbt project ' || c_project || ' args = ''compile --target ' || v_target
        || ' --target-path target/canonical --log-path logs/canonical'' writeback = false';
      select last_query_id() into :v_state_qid;
      select $1::boolean into :v_canon_ok from table(result_scan(:v_state_qid));
    exception
      when other then
        v_canon_ok := false;
        v_canon_err := sqlerrm;
    end;

    -- 7. PUBLISHED, release
    call analytics_ops.control.log_event(:p_unit, 'PUBLISHED', :v_wm, :v_run_id,
      object_construct('role', :v_role, 'state_query_id', :v_state_qid,
                       'canonical_ok', :v_canon_ok, 'canonical_error', :v_canon_err,
                       'input_clones', :v_inputs, 'inputs_cloned_at', :v_clone_ts));
    call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
    return 'PUBLISHED';

  exception
    when other then
      -- EXECUTE DBT PROJECT raises on a dbt failure (S3); the message carries dbt's output and
      -- a query id for SYSTEM$GET_DBT_LOG. A raised 'failed' (-20001) keeps the message set above.
      if (sqlcode <> -20001 or v_exc is null) then
        v_exc := sqlerrm;
      end if;
      if (v_granted) then
        begin
          execute immediate 'revoke usage on schema ' || c_db || '.' || v_build || ' from database role ' || v_reader;
        exception when other then null;
        end;
      end if;
      if (v_cloned) then
        begin
          call silver.ops.drop_input_clones(:p_unit) into :v_dropped;
        exception when other then null;
        end;
      end if;
      begin
        v_fail_qid := regexp_substr(:v_exc, 'system[$]get_dbt_log[(]''([^'']+)''[)]', 1, 1, 'e', 1);
        if (v_fail_qid is not null) then
          select system$get_dbt_log(:v_fail_qid) into :v_out;
        end if;
      exception when other then null;
      end;
      -- Attribution (SLD 4.3, 8): a source test, or a freeze failure naming a raw object or Time
      -- Travel, is ingestion's; any other test or model failure is the stewards'.
      if (contains(v_exc, 'in test source_')
          or (v_stage = 'freeze' and (contains(v_exc, '''RAW.') or contains(v_exc, 'ime travel')))) then
        v_class := 'source';
      elseif (contains(v_exc, 'in test ') or contains(v_exc, 'in model ')) then
        v_class := 'transform';
      end if;
      call analytics_ops.control.log_event(:p_unit, 'FAILED', :v_wm, :v_run_id,
        object_construct('stage', :v_stage, 'failure_class', :v_class, 'role', :v_role,
                         'exception', left(:v_exc, 4000), 'dbt_query_id', :v_fail_qid,
                         'stdout_tail', right(coalesce(:v_out, ''), 3000)));
      call analytics_ops.control.release_lease(:p_unit, :v_run_id) into :v_released;
      return 'FAILED:' || v_stage;
  end;
end;
$$;

grant usage on procedure silver.ops.publish_unit(varchar) to role silver_unit_base;

show procedures like 'PUBLISH_UNIT' in schema silver.ops;
