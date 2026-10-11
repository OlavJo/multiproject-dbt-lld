# Phase 2 smoke test: the publish steps, by hand

**Status:** scripts ready, not yet run.

## Why

Spikes S3, S6, S8 and S4 all run on the shared Silver dbt project through the publish procedure (SLD 10.4). Before building the procedure, confirm that each step works as a plain statement, so that a failure in S3 to S8 is attributable to the question being asked and not to plumbing.

## What is built

`dbt/silver/` (one project, one live-version object `silver.ops.silver_layer`, dbt Core 1.12.3):

| Piece | Where | SLD |
|---|---|---|
| Unit schema redirection (`<unit>__build` for the unit being published, published schema otherwise; `<schema>_<unit>` in dev) | `macros/unit_schemas.sql` | 10.4 |
| `ref` and `source` overrides: bare identifiers for views in the same schema; frozen-input sources redirected at compile time | `macros/relation_overrides.sql` | 10.5, S1 |
| The freeze: transient clones of every raw table of `<unit>_raw` at a UTC watermark | `macros/freeze_sources.sql` | 7.2 |
| One selector per unit (models, frozen-input sources, source tests) | `selectors.yml` | 10.3 |
| ERP unit: two base views, a CDC current-state incremental (contract enforced), a table; source tests on frozen inputs, output tests | `models/erp/` | 6, 8 |
| CRM unit: one base view and one table | `models/crm/` | 6 |
| One profile target per unit service role (`prod_erp`, `prod_crm`) and a `dev` target | `profiles.yml` | 10.4 |

Setup: `setup/06_silver_prereqs.sql` (second unit role, published schemas, simulated landing with a platform-owned landing-complete table and `raw.control.land_batch`, run-control additions) and `setup/07_silver_project.sql` (the project object, grants, `DEPLOYED` event).

## Checked offline (dbt Core 1.12.3 and dbt-snowflake 1.12.0, the Snowflake runtime versions)

`dbt parse` and `dbt compile --no-populate-cache` run against the project, with and without `--vars '{publish_unit: erp}'`:

- **Observed:** `unit_schema()` is **not available when a source's `schema:` property is rendered**: project macros are not in the context at that point (`'unit_schema' is undefined`). The frozen-input source therefore declares its published schema, and the `source()` override redirects it at compile time. LLD note for S6.
- **Observed:** the compiled base view reads `from raw__orders` (bare identifier); a table reads `SILVER.erp__build.stg_erp__accounts` (qualified); a source test reads `silver.erp__build.raw__accounts`. Without `publish_unit`, all resolve to the published `erp` schema. The `source()` override is also applied to generic tests on sources.
- Not checkable offline: the incremental model and the contract (they query the warehouse), the freeze macro, and everything after.

## Method: `p2_smoke.sql`

Two rounds. Round 1 publishes the state left by setup/06. Round 2 lands a new batch first, which exercises the incremental merge, a freeze at a new watermark and a second swap. Each round: clone the published schema `WITH MANAGED ACCESS`; freeze via `EXECUTE DBT PROJECT ... run-operation freeze_sources` (arguments built dynamically with `EXECUTE IMMEDIATE`); `dbt build --selector unit_erp`; audit the build schema; grant, swap, revoke (S2); then consumer checks (rows, masked PII in a materialised model, frozen input and build schema invisible).

Questions it answers on the way:

1. Does `EXECUTE IMMEDIATE` run `EXECUTE DBT PROJECT` with dynamic arguments, and can its result be read with `RESULT_SCAN`?
2. Does `--target` select the per-unit service role, and can the unit role execute the project object?
3. Do `ref`/`source` overrides, the schema redirection, `run-operation` and the per-unit selector work in the managed runtime?
4. Do dbt's `grants` config, incremental merge and contract enforcement work on a table cloned from the published schema?
5. Does propagation mask PII in a table built from a view over a frozen input?

Findings feed S3 (the result read), S6 (macros across targets), S8 (concurrent units) and S4 (history).

## Result (2026-10-06, `evidence/P2_smoke_20261006.csv`)

**30 of 32 cases PASS.** Observed: `EXECUTE IMMEDIATE` runs `EXECUTE DBT PROJECT` with dynamic `ARGS` and `RESULT_SCAN` reads its result; `--target` runs the build under the unit role; freeze, source tests, build, output tests, grant/swap/revoke and consumer reads work as plain statements; the incremental model merges on a table cloned from the published schema; the base view's DDL is bare (`from raw__orders`) and the published view reads the swapped frozen input; consumers cannot read frozen inputs or the build schema.

**The 2 FAILs (P2.S1.13, P2.S2.13):** `erp_accounts.email` in clear for the consumer. Cause (S9f): the raw column was tagged `PII_DECL`, which propagates on data movement only and stops at the base view. Fix: `PII_DEP` (`ON_DEPENDENCY_AND_DATA_MOVEMENT`). `p2_smoke_r3.sql` re-tags the raw column and republishes ERP with no new batch; setup/05 and setup/06 now use `PII_DEP`.
