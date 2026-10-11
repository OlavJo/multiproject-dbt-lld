-- =============================================================================
-- Spike S1: View-relative resolution across SWAP and CLONE (load-bearing)
-- See README.md in this folder for the question, method and result.
--
-- Run as: SVC_SILVER_ERP (the unit service role, which owns all schemas used).
-- Idempotent: drops and recreates its own schemas.
--
-- Throughout, the SESSION schema is deliberately set to a decoy schema
-- (silver.s1_other) that holds its own table T, so any resolution against the
-- session rather than the view's schema shows up as the marker 'OTHER'.
-- CREATE SCHEMA switches the session to the new schema (observed, run 1), so
-- the decoy is re-asserted after every CREATE SCHEMA.
-- =============================================================================

use role svc_silver_erp;
use secondary roles none;
use warehouse spike_wh;

set run_id = (select uuid_string());

-- Reset ------------------------------------------------------------------------
drop schema if exists silver.s1_pub;
drop schema if exists silver.s1_build;
drop schema if exists silver.s1_clone;
drop schema if exists silver.s1_other;

-- Initial state ------------------------------------------------------------------
-- s1_pub plays a published unit schema; s1_other is a decoy and a cross-unit target.
create schema silver.s1_pub;
create schema silver.s1_other;

create table silver.s1_pub.t   (id int, marker varchar) as select 1, 'OLD';
create table silver.s1_other.t (id int, marker varchar) as select 1, 'OTHER';
create table silver.s1_other.u (id int, marker varchar) as select 1, 'ONLY_IN_OTHER';

use schema silver.s1_other;   -- decoy session schema from here on

-- Part A: creation and resolution of a bare identifier ---------------------------
call spike_lab.evidence.probe($run_id, 'S1', 'S1.01',
  'CREATE VIEW accepts a bare (unqualified) identifier',
  $$create or replace view silver.s1_pub.v as select id, marker from t$$,
  '%successfully created%');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.02',
  'Bare identifier resolves in the VIEW''s schema, not the session schema (session = s1_other)',
  $$select marker from silver.s1_pub.v$$, 'OLD');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.03',
  'Stored view text keeps the bare identifier (binding is not expanded at creation)',
  $$select get_ddl('view', 'silver.s1_pub.v')$$, '%from t%');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.04',
  'No fallback to the session schema: a name that exists only in the session schema is rejected',
  $$create or replace view silver.s1_pub.v_u as select id, marker from u$$,
  'ERROR:%');

-- Same-schema view-on-view and a semantic view, in the published state
create or replace view silver.s1_pub.v2 as select marker from v;

call spike_lab.evidence.probe($run_id, 'S1', 'S1.05',
  'CREATE SEMANTIC VIEW accepts a bare table name',
  $$create or replace semantic view silver.s1_pub.sv
      tables ( t primary key (id) )
      dimensions ( t.marker_dim as marker )
      metrics ( t.row_count as count(*) )$$,
  '!ERROR:%');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.06',
  'Semantic view with bare table name resolves in its own schema',
  $$select marker_dim from semantic_view(silver.s1_pub.sv dimensions t.marker_dim)$$,
  'OLD');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.07',
  'Stored semantic view text keeps the bare table name',
  $$select get_ddl('semantic_view', 'silver.s1_pub.sv')$$, null);

-- Part B: schema CLONE rebinds views to the cloned siblings (SLD 10.5, 10.9) ----
create or replace schema silver.s1_clone clone silver.s1_pub;
use schema silver.s1_other;   -- re-assert decoy
create or replace table silver.s1_clone.t (id int, marker varchar) as select 1, 'CLONED';

call spike_lab.evidence.probe($run_id, 'S1', 'S1.10',
  'Cloned view reads the CLONE''s T, not the source schema''s T',
  $$select marker from silver.s1_clone.v$$, 'CLONED');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.11',
  'Cloned view-on-view reads the clone''s siblings',
  $$select marker from silver.s1_clone.v2$$, 'CLONED');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.12',
  'Cloned semantic view reads the clone''s T',
  $$select marker_dim from semantic_view(silver.s1_clone.sv dimensions t.marker_dim)$$,
  'CLONED');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.13',
  'Source schema unaffected by the clone',
  $$select marker from silver.s1_pub.v$$, 'OLD');

-- Part C: publication cycle 1, clone -> rebuild -> SWAP (SLD 10.4 steps 2 to 5) --
-- Step 2: clone last good state into the build schema
create or replace schema silver.s1_build clone silver.s1_pub;
use schema silver.s1_other;   -- re-assert decoy

-- Step 4: the build replaces T and recreates views as dbt would, with the
-- same-schema reference rendered bare (SLD 10.5) ...
create or replace table silver.s1_build.t (id int, marker varchar) as select 1, 'NEW';
create or replace view  silver.s1_build.v  as select id, marker from t;
create or replace view  silver.s1_build.v2 as select marker from v;
create or replace semantic view silver.s1_build.sv
  tables ( t primary key (id) )
  dimensions ( t.marker_dim as marker )
  metrics ( t.row_count as count(*) );
-- ... a CONTROL view rendered fully qualified, as dbt does by default ...
create or replace view  silver.s1_build.vq as select id, marker from silver.s1_build.t;
-- ... and a cross-unit view, fully qualified as SLD 10.7 rule 2 requires
create or replace view  silver.s1_build.vx as select id, marker from silver.s1_other.t;

call spike_lab.evidence.probe($run_id, 'S1', 'S1.20',
  'Before swap: published view still reads OLD',
  $$select marker from silver.s1_pub.v$$, 'OLD');

-- Step 5: atomic publish
alter schema silver.s1_build swap with silver.s1_pub;

call spike_lab.evidence.probe($run_id, 'S1', 'S1.21',
  'KEY: after swap, bare-identifier view under the published name reads the NEW sibling',
  $$select marker from silver.s1_pub.v$$, 'NEW');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.22',
  'After swap, view-on-view under the published name reads NEW',
  $$select marker from silver.s1_pub.v2$$, 'NEW');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.23',
  'After swap, semantic view under the published name reads NEW',
  $$select marker_dim from semantic_view(silver.s1_pub.sv dimensions t.marker_dim)$$,
  'NEW');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.24',
  'After swap, the moved (old) schema''s view reads its own OLD sibling',
  $$select marker from silver.s1_build.v$$, 'OLD');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.25',
  'CONTROL: fully qualified view follows the build NAME after swap and reads stale OLD (the hazard SLD 10.5 removes)',
  $$select marker from silver.s1_pub.vq$$, 'OLD');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.26',
  'Cross-unit fully qualified view is unaffected by the swap',
  $$select marker from silver.s1_pub.vx$$, 'OTHER');

-- Part D: publication cycle 2, clone of a swapped schema, views NOT recreated ----
-- Shows the binding holds across repeated cycles, including for views the build
-- did not touch (dbt may skip unchanged views in future optimisations).
create or replace schema silver.s1_build clone silver.s1_pub;
use schema silver.s1_other;   -- re-assert decoy
create or replace table silver.s1_build.t (id int, marker varchar) as select 1, 'NEWER';
alter schema silver.s1_build swap with silver.s1_pub;

call spike_lab.evidence.probe($run_id, 'S1', 'S1.30',
  'Cycle 2: untouched cloned view, after swap, reads NEWER',
  $$select marker from silver.s1_pub.v$$, 'NEWER');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.31',
  'Cycle 2: untouched cloned semantic view, after swap, reads NEWER',
  $$select marker_dim from semantic_view(silver.s1_pub.sv dimensions t.marker_dim)$$,
  'NEWER');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.32',
  'Cycle 2: moved schema holds the previous version',
  $$select marker from silver.s1_build.v$$, 'NEW');

-- Part E: semantic views referencing the PUBLISHED name (candidate fix) --------
-- Run 1 showed semantic views resolve bare table names at creation, against the
-- session schema, and store them fully qualified. Candidate fix: in the build
-- schema, reference the PUBLISHED name. Before the swap the semantic view reads
-- the published (previous) tables, unseen by consumers; after the swap it sits
-- under the published name and reads the newly published tables.
create or replace schema silver.s1_build clone silver.s1_pub;
use schema silver.s1_other;   -- re-assert decoy
create or replace table silver.s1_build.t (id int, marker varchar) as select 1, 'E_NEW';

call spike_lab.evidence.probe($run_id, 'S1', 'S1.40',
  'Semantic view in the build schema can reference the PUBLISHED table name',
  $$create or replace semantic view silver.s1_build.sv_pub
      tables ( t as silver.s1_pub.t primary key (id) )
      dimensions ( t.marker_dim as marker )
      metrics ( t.row_count as count(*) )$$,
  '!ERROR:%');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.41',
  'Before swap: build-schema semantic view reads the currently published table (NEWER)',
  $$select marker_dim from semantic_view(silver.s1_build.sv_pub dimensions t.marker_dim)$$,
  'NEWER');

alter schema silver.s1_build swap with silver.s1_pub;

call spike_lab.evidence.probe($run_id, 'S1', 'S1.42',
  'KEY: after swap, semantic view referencing the published name reads the newly published table',
  $$select marker_dim from semantic_view(silver.s1_pub.sv_pub dimensions t.marker_dim)$$,
  'E_NEW');

call spike_lab.evidence.probe($run_id, 'S1', 'S1.43',
  'Stored text of the published-name semantic view',
  $$select get_ddl('semantic_view', 'silver.s1_pub.sv_pub')$$, null);

-- Limitation: a semantic view that uses a column new in this build. The published
-- table does not have the column yet, so creation is expected to fail.
create or replace schema silver.s1_build clone silver.s1_pub;
use schema silver.s1_other;   -- re-assert decoy
create or replace table silver.s1_build.t (id int, marker varchar, extra varchar)
  as select 1, 'E2', 'X';

call spike_lab.evidence.probe($run_id, 'S1', 'S1.44',
  'Limitation: published-name semantic view cannot use a column that exists only in the build',
  $$create or replace semantic view silver.s1_build.sv_extra
      tables ( t as silver.s1_pub.t primary key (id) )
      dimensions ( t.extra_dim as extra )
      metrics ( t.row_count as count(*) )$$,
  'ERROR:%');

-- Evidence ---------------------------------------------------------------------
select case_id, outcome, description, observed, expected, role_name, secondary_roles, observed_at
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
-- Export this result as evidence/S1_<yyyymmdd>.csv
