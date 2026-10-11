-- =============================================================================
-- Spike S9d: does a manual tag override on a derived column survive later DML?
-- See README.md in this folder, section S9d. Closes the S9b open item.
-- Requires setup/05_governance.sql and raw.erp.customers (S9) with `phone`
-- tagged GOVERNANCE.POLICIES.PII_AUTO (propagating, masked by policy).
--
-- Declassification of an over-tagged derived column (S9b: e.g. length(phone))
-- would be an explicit, reviewed act. It only works if it lasts. Two overrides:
--   SET    change the propagated tag's value on the target column
--   UNSET  remove the propagated tag from the target column
-- each followed by the DML dbt runs later: MERGE (update and insert),
-- INSERT ... SELECT, and a full-refresh CTAS. Also: does a schema clone (the
-- publish step) carry the override?
-- Probes run as the unit service role; consumer reads as ANALYST_TIER1.
-- Cases with no predicted outcome are INFO (expected NULL). Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

use role svc_silver_erp;
drop schema if exists silver.s9d_b;
drop schema if exists silver.s9d;
create schema silver.s9d with managed access;
grant usage on schema silver.s9d to database role silver.reader;

create transient table silver.s9d.raw__customers clone raw.erp.customers;

-- Two targets built the way dbt builds an incremental model: created, then MERGE
create table silver.s9d.t_set   (id int, phone varchar);
create table silver.s9d.t_unset (id int, phone varchar);
merge into silver.s9d.t_set t
  using (select id, phone from silver.s9d.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
merge into silver.s9d.t_unset t
  using (select id, phone from silver.s9d.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
grant select on table silver.s9d.t_set   to database role silver.reader;
grant select on table silver.s9d.t_unset to database role silver.reader;

-- Baseline ------------------------------------------------------------------------
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.01', 'Baseline: propagated tag on t_set.phone',
  $$select listagg(column_name || '=' || tag_name || ':' || tag_value, '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_set', 'table'))$$,
  '%PHONE=PII_AUTO:%');
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.02', 'Baseline: propagated tag on t_unset.phone',
  $$select listagg(column_name || '=' || tag_name || ':' || tag_value, '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_unset', 'table'))$$,
  '%PHONE=PII_AUTO:%');

-- Override 1: SET a different value on the propagated tag ------------------------
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.10', 'Override by SET TAG value on a propagated tag',
  $$alter table silver.s9d.t_set modify column phone set tag governance.policies.pii_auto = 'reviewed'$$,
  null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.11', 'Tag value on t_set.phone after the SET',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_set', 'table'))
    where column_name = 'PHONE'$$,
  null);

-- Override 2: UNSET the propagated tag -------------------------------------------
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.20', 'Override by UNSET TAG on a propagated tag',
  $$alter table silver.s9d.t_unset modify column phone unset tag governance.policies.pii_auto$$,
  null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.21', 'Tags on t_unset.phone after the UNSET (expected none)',
  $$select count(*) from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_unset', 'table'))
    where column_name = 'PHONE'$$,
  '0');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.22', 'Consumer reads t_unset.phone after UNSET (clear = declassified)',
  $$select phone from silver.s9d.t_unset where id = 1$$, null);
use role svc_silver_erp;

-- Later DML 1: MERGE update of existing rows and insert of new rows -----------------
merge into silver.s9d.t_set t
  using (select id, phone || ' v2' as phone from silver.s9d.raw__customers
         union all select id + 1000, phone from silver.s9d.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
merge into silver.s9d.t_unset t
  using (select id, phone || ' v2' as phone from silver.s9d.raw__customers
         union all select id + 1000, phone from silver.s9d.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
select system$wait(10);

call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.30', 'After MERGE: tags on t_set.phone',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_set', 'table'))
    where column_name = 'PHONE'$$, null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.31', 'After MERGE: tags on t_unset.phone (does propagation reapply?)',
  $$select count(*) from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_unset', 'table'))
    where column_name = 'PHONE'$$, null);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.32', 'After MERGE: consumer reads t_set.phone',
  $$select phone from silver.s9d.t_set where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.33', 'After MERGE: consumer reads t_unset.phone',
  $$select phone from silver.s9d.t_unset where id = 1$$, null);
use role svc_silver_erp;

-- Later DML 2: INSERT ... SELECT ----------------------------------------------------
insert into silver.s9d.t_set   select id + 2000, phone from silver.s9d.raw__customers;
insert into silver.s9d.t_unset select id + 2000, phone from silver.s9d.raw__customers;
select system$wait(10);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.40', 'After INSERT SELECT: tags on t_set.phone',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_set', 'table'))
    where column_name = 'PHONE'$$, null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.41', 'After INSERT SELECT: tags on t_unset.phone',
  $$select count(*) from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_unset', 'table'))
    where column_name = 'PHONE'$$, null);

-- Publish step: a managed-access schema clone (as S2 variant E) ------------------------
create schema silver.s9d_b clone silver.s9d with managed access;
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.50', 'Schema clone: tags on t_set.phone in the clone',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d_b.t_set', 'table'))
    where column_name = 'PHONE'$$, null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.51', 'Schema clone: tags on t_unset.phone in the clone',
  $$select count(*) from table(silver.information_schema.tag_references_all_columns('silver.s9d_b.t_unset', 'table'))
    where column_name = 'PHONE'$$, null);

-- Full refresh: CREATE OR REPLACE TABLE AS SELECT (dbt --full-refresh) ---------------------
create or replace table silver.s9d.t_set   as select id, phone from silver.s9d.raw__customers;
create or replace table silver.s9d.t_unset as select id, phone from silver.s9d.raw__customers;
select system$wait(10);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.60', 'After full-refresh CTAS: tags on t_set.phone (override lost?)',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_set', 'table'))
    where column_name = 'PHONE'$$, null);
call spike_lab.evidence.probe($run_id, 'S9d', 'S9d.61', 'After full-refresh CTAS: tags on t_unset.phone (override lost?)',
  $$select count(*) from table(silver.information_schema.tag_references_all_columns('silver.s9d.t_unset', 'table'))
    where column_name = 'PHONE'$$, null);

-- Evidence ----------------------------------------------------------------------
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
