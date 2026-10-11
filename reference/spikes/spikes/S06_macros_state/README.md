# S6: macros and state across targets

**Status:** **complete** (2026-10-07). Evidence: `S6a_run1`, `S6b_run1`, `S6b_run2`, `S6b_listings`, `S6a2_dev` (all under `evidence/`).

## Question

SLD 10.4, 10.5, 3.2, 14 (S6): (1) do the `generate_schema_name`, `ref` and `source` overrides give the right schemas and keep the S1 bare-identifier rule across the **dev**, **CI** and **prod** targets, without touching the published schemas? (2) can CI select what a change touches with `state:modified` and build only that with `--defer`, against the **canonical state** that the publish procedure records (SLD 3.2), and what does a target-dependent schema do to `state:modified`?

Known so far: the canonical state is a stage path (`SYSTEM$LOCATE_DBT_ARTIFACTS(<query id>)` returns `snow://dbt/SILVER.OPS.SILVER_LAYER/results/query_id_<id>/`, S8g) that survives `ADD VERSION` deployments; how to hand such a path to `--state` is the open mechanical question.

## What is added

- `profiles.yml`: a `ci` target (the unit's service role; schema `ci`, so objects land in `ci_<unit>`).
- `models/erp/stg_erp__accounts.sql`: a new leading comment, the one change `state:modified` must detect (a body change, nothing else).

## Method

| Part | What |
|---|---|
| `s06a` | A publication through the procedure records the canonical state Q0 of the deployed code. The steward builds the ERP unit in the **dev** target (`dev_erp`): objects land there, a view keeps its bare identifier, PII is masked for the developer, and the published schema is untouched (fingerprint before and after) |
| `s06b` | Deploy the changed code in place (`ADD VERSION`). **Find how to pass the canonical state to `--state`** (four candidate forms tried and the failures recorded). `state:modified` in the prod target (expected: only `stg_erp__accounts`); in the **CI** target (`ci_erp` against the state's `erp`: does every node differ in `relation`?); with the `.body` sub-selector. The CI slim build: freeze into `ci_erp`; `build --select erp_accounts` **without** `--defer` (expected to fail: the parent is not in `ci_erp`) and **with** it (the parent is read from the published schema); then `state:modified.body+ --defer`. The published schema is untouched |

## Run 1 (2026-10-07: `evidence/S6a_run1_20261007.csv`, `evidence/S6b_run1_20261007.csv`)

**Observed:**

- **A publication through the procedure records the canonical state Q0 of the deployed code** (S6a.01 to S6a.03), and `ADD VERSION` of changed code (the comment in `stg_erp__accounts.sql`, and the `ci` target) is accepted while **Q0 still locates after it** (S6b.01, S6b.02): the S8g result holds for a content change.
- **A stage path given to `--state` is not read.** All forms (`.../query_id_<Q0>/`, `.../target/`, `.../target`, and the last successful run's target) gave `Got a state selector method, but no comparison manifest`: dbt received the argument as a local path and found no manifest there (a nonexistent path gives a different error: `Could not find manifest in --state path`). The documented mechanism is **`IMPORTS = ('<stage path>' AS 'state')` on `EXECUTE DBT PROJECT`, which mounts the files at `./imports/state`, with `--state ./imports/state` in `ARGS`** (Snowflake documentation on Slim CI and defer, found by search; the page itself was not readable from this environment, so the syntax is to be confirmed by run 2). Imports apply to one execution only; nothing is copied into the live version.
- **The negative control behaves as expected:** without `--defer`, `build --select erp_accounts` in the CI target fails because its parent view is not in `ci_erp` (`Object 'SILVER.CI_ERP.STG_ERP__ACCOUNTS' does not exist`, S6b.51); the published schema was not touched by any CI step (S6b.57).
- **Defect, fixed: the freeze macro did not create the developer or CI schema** (`Schema 'SILVER.DEV_ERP' does not exist`, S6a.10; `SILVER.CI_ERP`, S6b.50). In prod the publish procedure creates the build schema as a clone of the published one; dev and CI have no such step. The macro now runs `CREATE SCHEMA IF NOT EXISTS` in non-prod targets only (in prod it would hide a missing clone). The dev build (S6a.11) and everything after it failed for that reason alone.

Run 2: `s06b_state_defer.sql` uses the `IMPORTS` syntax and redeploys (`ADD VERSION`, which carries the macro fix; Q0 is unchanged because nothing is published in between); then `s06a2_dev_only.sql` repeats the dev part.

## Run 2 (`evidence/S6b_run2_20261007.csv`): state through `IMPORTS`, `--defer` and the slim build work

- **State is mounted with `IMPORTS = ('<path>' AS 'state')` and read with `--state ./imports/state`.** The path must be the canonical execution's **`target/` directory**: `SYSTEM$LOCATE_DBT_ARTIFACTS(<Q0>)` returns `.../query_id_<Q0>/`, which failed (`Got a state selector method, but no comparison manifest`); **`.../query_id_<Q0>/target/` worked** (S6b.state_form_0, S6b.state_form_1). So the recorded query id of the `PUBLISHED` event is enough, with `target/` appended.
- **`--defer` against the imported state works in the CI target.** `build --select erp_accounts` without `--defer` fails (S6b.51: the parent view is not in `ci_erp`); with `--defer` it succeeds (S6b.52), **the parent is read from the published `erp` schema and not rebuilt** (only `ERP_ACCOUNTS` exists in `ci_erp`, S6b.53), and the result has the same row count as the published table (S6b.54).
- **The slim build builds exactly what a change touches:** `build --select state:modified.body+ --defer` succeeded (S6b.55) and `ci_erp` holds the changed view and its dependent table, `ERP_ACCOUNTS, STG_ERP__ACCOUNTS`, and nothing of the unchanged orders models (S6b.56). The published schema was untouched (S6b.57).
- The four `list` cases (`evidence/S6b_listings_20261007.csv`) show what each selection picks:

| Case | Selection | Listed |
|---|---|---|
| B30 | prod target, `state:modified` | `stg_erp__accounts` |
| **B40** | **CI target, `state:modified`** (`ci_erp` against the state's `erp`) | **`stg_erp__accounts`** (not every model) |
| B41 | CI target, `state:modified.body` | `stg_erp__accounts` |
| B42 | CI target, `state:modified.body+` | `erp_accounts`, `stg_erp__accounts` |

**Observed, against my hypothesis: a target-dependent schema does not make every node "modified".** Plain `state:modified` in the CI target (schemas `ci_erp`) against the production state (schema `erp`) lists only the changed model, the same as `.body`. Probable reason, not verified in dbt's source: dbt compares the unrendered schema configuration (`+schema: erp`), not the rendered name that `generate_schema_name` produces per target. So the overrides do not disturb state selection, and CI can use `state:modified+` without sub-selectors.

## Conclusions for the design (SLD 3.2, 10.4, 10.5)

1. **The canonical state is usable by CI as designed.** The `PUBLISHED` event's `state_query_id` is enough: CI mounts `snow://dbt/<DB>.<SCHEMA>.<PROJECT>/results/query_id_<id>/target/` with `IMPORTS = ('<path>' AS 'state')` and passes `--state ./imports/state` (the `target/` directory, not the directory `LOCATE_DBT_ARTIFACTS` returns). The import lasts for one execution and does not touch the live version.
2. **`--defer` and `state:modified+` work against it** in a CI target whose schemas differ from production's: the changed models and what depends on them are built in `ci_<unit>`, parents are read from the published schema, the published schema is untouched, and a CI build without `--defer` fails as it should.
3. **The schema overrides do not disturb state selection**: `state:modified` agrees with `state:modified.body` across targets.
4. **dev and CI need a schema-creating step**: in prod the publish procedure creates the build schema; the freeze macro creates the dev or CI schema in non-prod targets (found in run 1: the first dev and CI freezes failed on the missing schema).
5. **CI needs its own frozen inputs**: the CI schema holds its own frozen clones of raw at a chosen watermark (`freeze_sources --target ci`), not the production unit's frozen inputs (which are not granted to anyone but the unit role).
6. **Not tested:** removing a model (`state:deleted`); a macro change (`state:modified.macros`); a CI schema per pull request (here a fixed `ci`); the dbt `--favor-state` flag; running CI under a role other than the unit's service role.

## Result: the dev target (`s06a2_dev_only.sql`, `evidence/S6a2_dev_20261007.csv`): all PASS

After the freeze macro creates the schema in non-prod targets, the steward builds the ERP unit in the **dev** target (no `publish_unit` variable):

| Case | Observed |
|---|---|
| S6a2.10, S6a2.11 | freeze and build succeed (source tests, models, output tests) |
| S6a2.12 | the objects land in **`silver.dev_erp`**: `ERP_ACCOUNTS, ERP_ORDERS_CURRENT, RAW__ACCOUNTS, RAW__ORDERS, STG_ERP__ACCOUNTS, STG_ERP__ORDERS, _FREEZE` (no `erp` or `erp__build` objects) |
| S6a2.13 | a base view keeps its **bare identifier** (`from raw__orders`): the S1 rule holds in dev |
| S6a2.14 | the dev table reads the dev view (rows present) |
| S6a2.15 | **PII is masked for the developer** (`***MASKED***` for the steward role, in both the frozen clone's tag and the propagated column) |
| S6a2.17 | **the published `erp` schema is untouched** (fingerprint of object names and last-altered times before and after) |

**S6 conclusions, complete:** the three targets (dev, CI, prod) route objects to `dev_<unit>`, `ci_<unit>` and `<unit>` or `<unit>__build` with the same overrides; views keep bare identifiers in all of them; the published schemas are never touched by dev or CI; developers see masked PII; state selection and `--defer` work across targets with the canonical state imported as above.
