-- =============================================================================
-- Spike S9c, part 2: read retained storage from ACCOUNT_USAGE
-- Run 2 to 24 hours after s09c_retained_storage.sql, and before the 1-day
-- retention of SILVER.S9C_RET1 expires the replaced clones.
--
-- INFORMATION_SCHEMA.TABLE_STORAGE_METRICS returned no rows on this account
-- for any role (observed), so the snapshots taken in the first script are
-- empty. ACCOUNT_USAGE.TABLE_STORAGE_METRICS has up to ~90 minutes of latency
-- and lists every table version (replaced clones appear with DELETED = TRUE).
-- Read-only observation: ACCOUNTADMIN is acceptable here (no privilege tested).
-- Idempotent: each run adds a new run id.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
use role accountadmin;
set run_id = (select uuid_string());

-- 1. Raw per-version rows
insert into spike_lab.evidence.observation
  select $run_id, 'S9c', 'S9c.2' || lpad(row_number() over (order by table_catalog, table_schema, table_name, deleted)::varchar, 2, '0'),
         'Storage version: ' || table_catalog || '.' || table_schema || '.' || table_name || ' deleted=' || deleted::varchar,
         'snowflake.account_usage.table_storage_metrics', null,
         'active_mb=' || round(active_bytes / 1048576, 1) || '; time_travel_mb=' || round(time_travel_bytes / 1048576, 1)
           || '; retained_for_clone_mb=' || round(retained_for_clone_bytes / 1048576, 1)
           || '; failsafe_mb=' || round(failsafe_bytes / 1048576, 1),
         'INFO', current_role(), current_secondary_roles(), sysdate(), current_version(),
         object_construct(*)
  from snowflake.account_usage.table_storage_metrics
  where (table_catalog = 'SILVER' and table_schema in ('S9C_RET1', 'S9C_RET0'))
     or (table_catalog = 'RAW' and table_name in ('S9C_SCATTERED', 'S9C_CLUSTERED'));

-- 2. Evidence: totals per table, split by live and replaced versions
select table_catalog || '.' || table_schema || '.' || table_name as table_name,
       count(*)                                                       as versions,
       count_if(deleted)                                              as replaced_versions,
       round(sum(iff(not deleted, active_bytes, 0)) / 1048576, 1)     as live_active_mb,
       round(sum(time_travel_bytes) / 1048576, 1)                     as time_travel_mb,
       round(sum(retained_for_clone_bytes) / 1048576, 1)              as retained_for_clone_mb,
       round(sum(failsafe_bytes) / 1048576, 1)                        as failsafe_mb
from snowflake.account_usage.table_storage_metrics
where (table_catalog = 'SILVER' and table_schema in ('S9C_RET1', 'S9C_RET0'))
   or (table_catalog = 'RAW' and table_name in ('S9C_SCATTERED', 'S9C_CLUSTERED'))
group by 1
order by 1;

-- 3. Evidence: every version row, for the detail
select table_catalog, table_schema, table_name, deleted, is_transient,
       round(active_bytes / 1048576, 1) active_mb, round(time_travel_bytes / 1048576, 1) time_travel_mb,
       round(retained_for_clone_bytes / 1048576, 1) retained_for_clone_mb, round(failsafe_bytes / 1048576, 1) failsafe_mb,
       table_created, table_dropped
from snowflake.account_usage.table_storage_metrics
where (table_catalog = 'SILVER' and table_schema in ('S9C_RET1', 'S9C_RET0'))
   or (table_catalog = 'RAW' and table_name in ('S9C_SCATTERED', 'S9C_CLUSTERED'))
order by table_catalog, table_schema, table_name, table_created;
