-- =============================================================================
-- Phase 2 / Step 10: the Core unit (Tier 0.5), prerequisites of spike S10
--
--   SVC_SILVER_CORE   service role of the Core unit. It INHERITS the ERP and CRM unit roles
--                     (grants of roles to the role): schema clones need privileges on every object
--                     of the cloned schema, including the frozen inputs, which are granted to no
--                     consumer (SLD 10.9: the clone runs under a steward-owned service role).
--                     This is a design choice under test; its cost (the Core role can alter the
--                     upstream units' objects) is recorded in the S10 write-up.
--   silver.core       the Core unit's published schema, owned by SVC_SILVER_CORE
--   run control       unit silver.core (tier T0.5), dependencies on silver.erp and silver.crm, lease
--
-- Requires setup/08 re-run (input clones in the publish procedure) and setup/06, 07.
-- Deploys the Core models with ALTER DBT PROJECT ... ADD VERSION (S8g).
-- Run as: USERADMIN, SECURITYADMIN, SYSADMIN, SILVER_STEWARD, SVC_SILVER_CORE (switches itself).
-- Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set me = (select current_user());
set git_ref = 'main';

use role useradmin;
create role if not exists svc_silver_core comment = 'Spike S10: service role of the Core unit (inherits the ERP and CRM unit roles)';
use role securityadmin;
grant role svc_silver_core to role sysadmin;
grant role svc_silver_core to user identifier($me);
grant role svc_silver_erp to role svc_silver_core;
grant role svc_silver_crm to role svc_silver_core;

use role sysadmin;
grant usage on warehouse spike_wh to role svc_silver_core;
grant usage on database spike_lab        to role svc_silver_core;
grant usage on schema spike_lab.evidence to role svc_silver_core;
grant select, insert on table spike_lab.evidence.observation to role svc_silver_core;
grant usage on procedure spike_lab.evidence.probe(varchar, varchar, varchar, varchar, varchar, varchar) to role svc_silver_core;

use role silver_steward;
grant usage, create schema on database silver to role svc_silver_core;
grant usage on schema silver.ops to role svc_silver_core;
grant usage on procedure silver.ops.publish_unit(varchar) to role svc_silver_core;
grant usage on procedure silver.ops.drop_input_clones(varchar) to role svc_silver_core;
grant usage on database analytics_ops       to role svc_silver_core;
grant usage on schema analytics_ops.control to role svc_silver_core;
grant usage on procedure analytics_ops.control.acquire_lease(varchar, varchar) to role svc_silver_core;
grant usage on procedure analytics_ops.control.release_lease(varchar, varchar) to role svc_silver_core;
grant usage on procedure analytics_ops.control.log_event(varchar, varchar, timestamp_ntz, varchar, variant) to role svc_silver_core;
grant select on table analytics_ops.control.unit_lease         to role svc_silver_core;
grant select on table analytics_ops.control.unit_dependencies  to role svc_silver_core;
grant select on table analytics_ops.control.units              to role svc_silver_core;
grant select on table analytics_ops.control.publish_log        to role svc_silver_core;
grant select on view  analytics_ops.control.unit_status        to role svc_silver_core;
grant select on view  analytics_ops.control.unit_has_new_input to role svc_silver_core;
grant select on view  analytics_ops.control.v_landing_complete to role svc_silver_core;

-- Deploy the Core models in place (the object keeps its grants, S8g) and grant the new role
alter git repository spike_lab.git.spikes_repo fetch;
set sql_add = (select 'alter dbt project silver.ops.silver_layer add version from ''@spike_lab.git.spikes_repo/branches/' || $git_ref || '/dbt/silver''');
call spike_lab.evidence.probe(uuid_string(), 'P2', 'P2.30', 'Deploy the Core models in place (ADD VERSION)', $sql_add, '!ERROR:%');
grant usage on dbt project silver.ops.silver_layer to role svc_silver_core;

use role svc_silver_core;
create schema if not exists silver.core with managed access;
grant usage on schema silver.core to database role silver.reader;

use role silver_steward;
merge into analytics_ops.control.units u
  using (select * from (values ('silver.core', 'T0.5', 30, 'unit_core', 'prod_core'))
         as v(unit, tier, max_runtime_minutes, selector, dbt_target)) s
  on u.unit = s.unit
  when matched then update set selector = s.selector, dbt_target = s.dbt_target, tier = s.tier
  when not matched then insert (unit, tier, max_runtime_minutes, selector, dbt_target)
    values (s.unit, s.tier, s.max_runtime_minutes, s.selector, s.dbt_target);
insert into analytics_ops.control.unit_lease (unit)
  select u.unit from analytics_ops.control.units u
  where not exists (select 1 from analytics_ops.control.unit_lease l where l.unit = u.unit);
merge into analytics_ops.control.unit_dependencies d
  using (select * from (values ('silver.core', 'silver.erp', 24), ('silver.core', 'silver.crm', 24))
         as v(unit, upstream_unit, max_age_hours)) s
  on d.unit = s.unit and d.upstream_unit = s.upstream_unit
  when matched then update set max_age_hours = s.max_age_hours
  when not matched then insert (unit, upstream_unit, max_age_hours) values (s.unit, s.upstream_unit, s.max_age_hours);
insert into analytics_ops.control.publish_log (unit, event_type, detail)
  select 'silver.core', 'DEPLOYED', object_construct('by', 'setup/10');

show grants to role svc_silver_core;
