-- =============================================================================
-- Spike S9e: declassification by a reserved tag value (follow-up to S9d)
-- See README.md in this folder. S9d showed UNSET is undone by the next MERGE
-- and that SET changes only the value. Candidate: a masking policy that reveals
-- a column whose tag value is the reserved value 'declassified'.
--
-- Uses its own tag and policy so S9/S9b/S9d keep their behaviour:
--   GOVERNANCE.POLICIES.PII_DECL   PROPAGATE = ON_DATA_MOVEMENT, masked by
--                                  MASK_PII_DECL_STRING (value-aware)
-- Cases: baseline propagation and masking; SET 'declassified' unmasks; the
-- override survives MERGE, INSERT, schema clone; a full refresh reverts it
-- (fails closed); who can declassify (APPLY on the tag).
-- Run as: GOVERNANCE_ADMIN (setup), PLATFORM_INGEST, SVC_SILVER_ERP,
--         ANALYST_TIER1. Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Setup 1: tag and value-aware policy (governance) -------------------------------
use role governance_admin;
create tag if not exists governance.policies.pii_decl
  propagate = on_data_movement
  comment = 'S9e: propagating PII tag; value declassified reveals the column';
create or replace masking policy governance.policies.mask_pii_decl_string
  as (v varchar) returns varchar ->
  case
    when current_role() in ('PLATFORM_INGEST', 'SVC_SILVER_ERP') then v
    when system$get_tag_on_current_column('governance.policies.pii_decl') = 'declassified' then v
    else '***MASKED***'
  end;
begin
  alter tag governance.policies.pii_decl set masking policy governance.policies.mask_pii_decl_string;
exception
  when other then
    alter tag governance.policies.pii_decl unset masking policy governance.policies.mask_pii_decl_string;
    alter tag governance.policies.pii_decl set masking policy governance.policies.mask_pii_decl_string;
end;
-- Only the platform tags raw. The unit role gets APPLY here as a control (case S9e.40
-- removes it); a real design decides who may declassify (LLD).
grant apply on tag governance.policies.pii_decl to role platform_ingest;
grant apply on tag governance.policies.pii_decl to role svc_silver_erp;

-- Setup 2: raw source (platform) --------------------------------------------------
use role platform_ingest;
create or replace table raw.erp.s9e_customers (id int, phone varchar, phone_len int);
insert into raw.erp.s9e_customers values (1, '+64 21 000 001', 14), (2, '+64 21 000 002', 14);
alter table raw.erp.s9e_customers modify column phone set tag governance.policies.pii_decl = 'phone';
grant select on table raw.erp.s9e_customers to role svc_silver_erp;

-- Setup 3: target built by CTAS then MERGE (dbt incremental) ----------------------
use role svc_silver_erp;
drop schema if exists silver.s9e_b;
drop schema if exists silver.s9e;
create schema silver.s9e with managed access;
grant usage on schema silver.s9e to database role silver.reader;
create transient table silver.s9e.raw__customers clone raw.erp.s9e_customers;
create table silver.s9e.t as select id, phone from silver.s9e.raw__customers where 1 = 0;
merge into silver.s9e.t t using (select id, phone from silver.s9e.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
grant select on table silver.s9e.t to database role silver.reader;
select system$wait(10);

call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.01', 'Propagated tag on the target',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9e.t', 'table')) where column_name = 'PHONE'$$,
  'PII_DECL:phone:PROPAGATED');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.02', 'Consumer reads the propagated column: masked', $$select phone from silver.s9e.t where id = 1$$, '***MASKED***');
use role svc_silver_erp;

-- Declassify: SET the reserved value -----------------------------------------------
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.10', 'SET the reserved value declassified',
  $$alter table silver.s9e.t modify column phone set tag governance.policies.pii_decl = 'declassified'$$, null);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.11', 'Consumer reads after declassification: clear', $$select phone from silver.s9e.t where id = 1$$, '+64 21 000 001');
use role svc_silver_erp;

-- Later DML ------------------------------------------------------------------------
merge into silver.s9e.t t
  using (select id, phone || ' v2' as phone from silver.s9e.raw__customers
         union all select id + 1000, phone from silver.s9e.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
select system$wait(10);
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.20', 'After MERGE: tag on target',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9e.t', 'table')) where column_name = 'PHONE'$$,
  'PII_DECL:declassified:MANUAL');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.21', 'After MERGE: consumer reads updated row: clear', $$select phone from silver.s9e.t where id = 1$$, '+64 21 000 001 v2');
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.22', 'After MERGE: consumer reads inserted row: clear', $$select phone from silver.s9e.t where id = 1001$$, '+64 21 000 001');
use role svc_silver_erp;

insert into silver.s9e.t select id + 2000, phone from silver.s9e.raw__customers;
select system$wait(10);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.23', 'After INSERT SELECT: consumer reads: clear', $$select phone from silver.s9e.t where id = 2001$$, '+64 21 000 001');
use role svc_silver_erp;

-- Publish step: managed-access schema clone ------------------------------------------
create schema silver.s9e_b clone silver.s9e with managed access;
grant usage on schema silver.s9e_b to database role silver.reader;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.30', 'Schema clone: tag on the cloned target',
  $$select listagg(tag_name || ':' || tag_value || ':' || nvl(apply_method, ''), '; ')
    from table(silver.information_schema.tag_references_all_columns('silver.s9e_b.t', 'table')) where column_name = 'PHONE'$$,
  'PII_DECL:declassified:MANUAL');
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.31', 'Schema clone: consumer reads the clone: clear', $$select phone from silver.s9e_b.t where id = 1$$, '+64 21 000 001 v2');
use role svc_silver_erp;

-- Full refresh: fails closed ---------------------------------------------------------
create or replace table silver.s9e.t as select id, phone from silver.s9e.raw__customers;
grant select on table silver.s9e.t to database role silver.reader;
select system$wait(10);
use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.32', 'After full-refresh CTAS: consumer reads: masked again (fails closed)', $$select phone from silver.s9e.t where id = 1$$, '***MASKED***');
use role svc_silver_erp;

-- Who can declassify -----------------------------------------------------------------
use role governance_admin;
revoke apply on tag governance.policies.pii_decl from role svc_silver_erp;
use role svc_silver_erp;
call spike_lab.evidence.probe($run_id, 'S9e', 'S9e.40', 'Unit role without APPLY on the tag tries to declassify',
  $$alter table silver.s9e.t modify column phone set tag governance.policies.pii_decl = 'declassified'$$, 'ERROR:%');
use role governance_admin;
grant apply on tag governance.policies.pii_decl to role svc_silver_erp;

-- Evidence ---------------------------------------------------------------------------
use role silver_steward;
select case_id, outcome, description, observed, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation where run_id = $run_id order by case_id;
