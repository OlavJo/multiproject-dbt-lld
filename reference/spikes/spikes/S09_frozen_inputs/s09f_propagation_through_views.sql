-- =============================================================================
-- Spike S9f: does tag propagation pass through a view? (follow-up to P2.S*.13)
-- See README.md in this folder.
--
-- P2 smoke test: a table (erp_accounts) built from a base view (stg_erp__accounts)
-- over a frozen input (a clone of raw.erp.accounts, tagged PII_DECL) showed the
-- email column in clear to the consumer. S9, S9b and S9e propagated through
-- clones and CTAS/DML from TABLES; none had a view in the chain.
-- Hypothesis: PROPAGATE = ON_DATA_MOVEMENT does not cross a view; the table is
-- created from view columns that carry no tag. Snowflake documents a separate
-- propagation mode for dependencies (views); the exact option name is tested here.
--
-- Part A  tags on each layer of the P2 chain (raw, frozen input, view, table)
-- Part B  controlled chain with two tags: PII_DECL (ON_DATA_MOVEMENT, control)
--         and PII_DEP (ON_DEPENDENCY_AND_DATA_MOVEMENT, candidate), both on one
--         source table, through a view into a CTAS table; tags on each layer and
--         what a consumer reads.
-- Run as: SVC_SILVER_ERP, GOVERNANCE_ADMIN, PLATFORM_INGEST, ANALYST_TIER1,
--         SILVER_STEWARD (final query). Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Part A: the P2 chain --------------------------------------------------------------
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.A1', 'Tags on raw.erp.accounts.email',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(raw.information_schema.tag_references_all_columns('raw.erp.accounts', 'table')) where column_name = 'EMAIL'$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.A2', 'Tags on the frozen input silver.erp.raw__accounts.email',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.erp.raw__accounts', 'table')) where column_name = 'EMAIL'$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.A3', 'Tags on the base view silver.erp.stg_erp__accounts.email',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.erp.stg_erp__accounts', 'table')) where column_name = 'EMAIL'$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.A4', 'Tags on the table silver.erp.erp_accounts.email',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.erp.erp_accounts', 'table')) where column_name = 'EMAIL'$$, null);

-- Part B setup: tag and value-aware policy with dependency propagation (governance) ---
use role governance_admin;
create tag if not exists governance.policies.pii_dep
  propagate = on_dependency_and_data_movement
  comment = 'S9f: propagates through views and on data movement; value declassified reveals';
create or replace masking policy governance.policies.mask_pii_dep_string
  as (v varchar) returns varchar ->
  case
    when current_role() in ('PLATFORM_INGEST', 'SVC_SILVER_ERP') then v
    when system$get_tag_on_current_column('governance.policies.pii_dep') = 'declassified' then v
    else '***MASKED***'
  end;
begin
  alter tag governance.policies.pii_dep set masking policy governance.policies.mask_pii_dep_string;
exception
  when other then
    alter tag governance.policies.pii_dep unset masking policy governance.policies.mask_pii_dep_string;
    alter tag governance.policies.pii_dep set masking policy governance.policies.mask_pii_dep_string;
end;
grant apply on tag governance.policies.pii_dep to role platform_ingest;
grant apply on tag governance.policies.pii_dep to role svc_silver_erp;

-- Part B: source with the control tag and the candidate tag (platform) ----------------
use role platform_ingest;
create or replace table raw.erp.s9f_src (id int, email_ctl varchar, email_dep varchar);
insert into raw.erp.s9f_src values (1, 'a@example.com', 'a@example.com'), (2, 'b@example.com', 'b@example.com');
alter table raw.erp.s9f_src modify column email_ctl set tag governance.policies.pii_decl = 'email';
alter table raw.erp.s9f_src modify column email_dep set tag governance.policies.pii_dep  = 'email';
grant select on table raw.erp.s9f_src to role svc_silver_erp;

-- Chain: frozen clone -> base view with expression -> CTAS table ----------------------
use role svc_silver_erp;
drop schema if exists silver.s9f;
create schema silver.s9f with managed access;
grant usage on schema silver.s9f to database role silver.reader;
create transient table silver.s9f.raw__src clone raw.erp.s9f_src;
create view silver.s9f.stg_src as
  select id, lower(email_ctl) as email_ctl, lower(email_dep) as email_dep from raw__src;
create table silver.s9f.t as select id, email_ctl, email_dep from silver.s9f.stg_src;
grant select on view  silver.s9f.stg_src to database role silver.reader;
grant select on table silver.s9f.t       to database role silver.reader;
select system$wait(15);

call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B1', 'Tags on the frozen clone',
  $$select listagg(column_name || '=' || tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ') within group (order by column_name)
    from table(silver.information_schema.tag_references_all_columns('silver.s9f.raw__src', 'table'))$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B2', 'Tags on the view (does a view column take a propagated tag?)',
  $$select nvl(listagg(column_name || '=' || tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ') within group (order by column_name), '<none>')
    from table(silver.information_schema.tag_references_all_columns('silver.s9f.stg_src', 'table'))$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B3', 'Tags on the CTAS table built from the view',
  $$select nvl(listagg(column_name || '=' || tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ') within group (order by column_name), '<none>')
    from table(silver.information_schema.tag_references_all_columns('silver.s9f.t', 'table'))$$, null);

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B4', 'Consumer reads the view, control column (PII_DECL)', $$select email_ctl from silver.s9f.stg_src where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B5', 'Consumer reads the view, candidate column (PII_DEP)', $$select email_dep from silver.s9f.stg_src where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B6', 'Consumer reads the table, control column (PII_DECL)', $$select email_ctl from silver.s9f.t where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9f', 'S9f.B7', 'Consumer reads the table, candidate column (PII_DEP): masked?', $$select email_dep from silver.s9f.t where id = 1$$, '***MASKED***');

-- Evidence ---------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by case_id;
