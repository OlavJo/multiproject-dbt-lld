-- =============================================================================
-- Spike S9b: limits of automatic tag propagation (PROPAGATE = ON_DATA_MOVEMENT)
-- See ../S09_frozen_inputs/README.md, section S9b.
-- Requires setup/05_governance.sql and S9 (raw.erp.customers with tagged
-- email (PII, plain) and phone (PII_AUTO, propagating)).
--
-- S9 showed that a CTAS copying a PII_AUTO column carries the tag and its
-- masking. S9b covers what dbt models actually do:
--   T1  incremental first build then MERGE (insert and update)
--   T2  INSERT ... SELECT into an existing table
--   T3  expressions on a tagged column (lower, sha2, left, length, coalesce)
--   T4  a tagged column arriving through a join
--   T5  one column combining two differently tagged columns (ON_CONFLICT)
--   T6  aggregates of a tagged column
-- For each table, every column's tags are recorded with
-- TAG_REFERENCES_ALL_COLUMNS (the full rows, including how each tag was
-- applied, are kept in DETAIL), immediately and again after 10 seconds.
-- Then the consumer's view of key columns is recorded.
-- Idempotent.
-- =============================================================================

use secondary roles none;
use warehouse spike_wh;
set run_id = (select uuid_string());

-- Second raw table with a propagating tag, for joins and conflicts
use role platform_ingest;
create or replace table raw.erp.contacts (customer_id int, alt_phone varchar);
insert into raw.erp.contacts values (1, '+64 9 000 101'), (2, '+64 9 000 102'), (3, '+64 9 000 103');
alter table raw.erp.contacts modify column alt_phone set tag governance.policies.pii_auto = 'alt_phone';
grant select on table raw.erp.contacts to role svc_silver_erp;

-- Frozen inputs in a scratch unit schema
use role svc_silver_erp;
drop schema if exists silver.s9b;
create schema silver.s9b with managed access;
grant usage on schema silver.s9b to database role silver.reader;

create transient table silver.s9b.raw__customers clone raw.erp.customers;
create transient table silver.s9b.raw__contacts  clone raw.erp.contacts;

-- T1: dbt incremental pattern. First build is CTAS from an empty selection
-- (the table exists, with no rows), then MERGE inserts, then MERGE updates.
create table silver.s9b.t1_incremental as
  select id, phone from silver.s9b.raw__customers where 1 = 0;
merge into silver.s9b.t1_incremental t
  using (select id, phone from silver.s9b.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);
merge into silver.s9b.t1_incremental t
  using (select id, phone || ' ext 1' as phone from silver.s9b.raw__customers where id = 1) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);

-- T1b: control for T1, the same pattern into a table created with explicit
-- column definitions (no CTAS at all)
create table silver.s9b.t1b_incremental_ddl (id int, phone varchar);
merge into silver.s9b.t1b_incremental_ddl t
  using (select id, phone from silver.s9b.raw__customers) s on t.id = s.id
  when matched then update set phone = s.phone
  when not matched then insert (id, phone) values (s.id, s.phone);

-- T2: INSERT ... SELECT into an existing, untagged table
create table silver.s9b.t2_insert (id int, phone varchar);
insert into silver.s9b.t2_insert select id, phone from silver.s9b.raw__customers;

-- T3: expressions on a tagged column
create table silver.s9b.t3_expr as
  select id,
         lower(phone)               as phone_lower,
         sha2(phone)                as phone_sha2,
         left(phone, 4)             as phone_prefix,
         length(phone)              as phone_length,
         coalesce(phone, 'unknown') as phone_coalesce,
         'x' || phone               as phone_concat_literal
  from silver.s9b.raw__customers;

-- T4: tagged columns through a join
create table silver.s9b.t4_join as
  select c.id, c.phone, k.alt_phone, c.name
  from silver.s9b.raw__customers c
  join silver.s9b.raw__contacts k on k.customer_id = c.id;

-- T5: one column combining two differently tagged columns
create table silver.s9b.t5_conflict as
  select c.id, c.phone || ' / ' || k.alt_phone as both_phones
  from silver.s9b.raw__customers c
  join silver.s9b.raw__contacts k on k.customer_id = c.id;

-- T6: aggregates of a tagged column
create table silver.s9b.t6_agg as
  select count(distinct phone) as phone_count, max(phone) as phone_max
  from silver.s9b.raw__customers;

-- Tags per table: immediately -------------------------------------------------
insert into spike_lab.evidence.observation
  select $run_id, 'S9b', 'S9b.1' || t.n || 'a', 'Tags on ' || t.tbl || ' (immediately)',
         'tag_references_all_columns(' || t.tbl || ')', null,
         nvl(r.tags, '<none>'), 'INFO',
         current_role(), current_secondary_roles(), sysdate(), current_version(), r.detail
  from (select 1 n, 't1_incremental' tbl union all select 2, 't1b_incremental_ddl' union all
        select 3, 't2_insert' union all select 4, 't3_expr' union all select 5, 't4_join' union all
        select 6, 't5_conflict' union all select 7, 't6_agg') t
  left join (
    select 't1_incremental' tbl, listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name) tags, array_agg(object_construct(*)) detail
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t1_incremental', 'table'))
    union all
    select 't1b_incremental_ddl', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t1b_incremental_ddl', 'table'))
    union all
    select 't2_insert', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t2_insert', 'table'))
    union all
    select 't3_expr', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t3_expr', 'table'))
    union all
    select 't4_join', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t4_join', 'table'))
    union all
    select 't5_conflict', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t5_conflict', 'table'))
    union all
    select 't6_agg', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t6_agg', 'table'))
  ) r on r.tbl = t.tbl;

-- Tags per table: after 10 seconds (propagation may be asynchronous) ----------
select system$wait(10);

insert into spike_lab.evidence.observation
  select $run_id, 'S9b', 'S9b.1' || t.n || 'b', 'Tags on ' || t.tbl || ' (after 10 s)',
         'tag_references_all_columns(' || t.tbl || ')', null,
         nvl(r.tags, '<none>'), 'INFO',
         current_role(), current_secondary_roles(), sysdate(), current_version(), r.detail
  from (select 1 n, 't1_incremental' tbl union all select 2, 't1b_incremental_ddl' union all
        select 3, 't2_insert' union all select 4, 't3_expr' union all select 5, 't4_join' union all
        select 6, 't5_conflict' union all select 7, 't6_agg') t
  left join (
    select 't1_incremental' tbl, listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name) tags, array_agg(object_construct(*)) detail
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t1_incremental', 'table'))
    union all
    select 't1b_incremental_ddl', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t1b_incremental_ddl', 'table'))
    union all
    select 't2_insert', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t2_insert', 'table'))
    union all
    select 't3_expr', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t3_expr', 'table'))
    union all
    select 't4_join', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t4_join', 'table'))
    union all
    select 't5_conflict', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t5_conflict', 'table'))
    union all
    select 't6_agg', listagg(column_name || '=' || tag_name || ':' || tag_value, '; ') within group (order by column_name, tag_name), array_agg(object_construct(*))
      from table(silver.information_schema.tag_references_all_columns('silver.s9b.t6_agg', 'table'))
  ) r on r.tbl = t.tbl;

-- What the consumer sees ---------------------------------------------------------
grant select on all tables in schema silver.s9b to database role silver.reader;
revoke select on table silver.s9b.raw__customers from database role silver.reader;
revoke select on table silver.s9b.raw__contacts  from database role silver.reader;

use role analyst_tier1;
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.20', 'T1: phone after incremental MERGE inserts (row 2)',
  $$select phone from silver.s9b.t1_incremental where id = 2$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.21', 'T1: phone after incremental MERGE update (row 1)',
  $$select phone from silver.s9b.t1_incremental where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.22', 'T1b: phone after MERGE into a DDL-created table',
  $$select phone from silver.s9b.t1b_incremental_ddl where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.23', 'T2: phone after INSERT ... SELECT',
  $$select phone from silver.s9b.t2_insert where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.24', 'T3: lower(phone)',
  $$select phone_lower from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.25', 'T3: sha2(phone)',
  $$select phone_sha2 from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.26', 'T3: left(phone, 4)',
  $$select phone_prefix from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.27', 'T3: length(phone) (numeric; the masking policy is for strings)',
  $$select phone_length from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.28', 'T3: coalesce(phone, ...)',
  $$select phone_coalesce from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.29', 'T3: ''x'' || phone',
  $$select phone_concat_literal from silver.s9b.t3_expr where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.30', 'T4: phone through a join',
  $$select phone from silver.s9b.t4_join where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.31', 'T4: alt_phone through a join',
  $$select alt_phone from silver.s9b.t4_join where id = 1$$, '***MASKED***');
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.32', 'T5: column combining two differently tagged columns',
  $$select both_phones from silver.s9b.t5_conflict where id = 1$$, null);
call spike_lab.evidence.probe($run_id, 'S9b', 'S9b.33', 'T6: max(phone)',
  $$select phone_max from silver.s9b.t6_agg$$, null);

-- Evidence ---------------------------------------------------------------------
use role svc_silver_erp;
select case_id, outcome, description, observed, expected, role_name, observed_at, detail
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Export as evidence/S9b_<yyyymmdd>.csv (include the DETAIL column: it records
-- how each tag was applied)
