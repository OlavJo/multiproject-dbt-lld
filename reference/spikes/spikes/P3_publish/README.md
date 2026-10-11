# Phase 2: the publish procedure

**Status:** scripts ready, not yet run (`setup/08_publish_procedure.sql`, `p3_publish.sql`).

`silver.ops.publish_unit(p_unit)` is the generic, caller's-rights procedure of SLD 10.4, parameterised by unit and driven by run-control configuration (`units.selector`, `units.dbt_target`, `unit_dependencies`). It returns `PUBLISHED`, `SKIPPED:<reason>` or `FAILED:<stage>`, and always releases the lease.

| Step | Statement |
|---|---|
| 0 | `acquire_lease` (S12); held: log `SKIPPED` (locked), stop |
| 1 | Gate: every upstream watermark within `max_age_hours`; `unit_has_new_input` (an upstream `PUBLISHED`, or a `DEPLOYED`, since this unit last published) |
| 2 | Log `STARTED` (watermark = minimum upstream watermark, SLD 11.2); `CREATE OR REPLACE SCHEMA <unit>__build CLONE <unit> WITH MANAGED ACCESS` |
| 3 | `EXECUTE DBT PROJECT ... run-operation freeze_sources`, result read |
| 4 | `EXECUTE DBT PROJECT ... build --selector <unit selector>`, result read |
| 5 | grant `USAGE` on the build schema, `SWAP WITH`, revoke (S2) |
| 6 | Canonical `compile` with `WRITEBACK = FALSE`; query id recorded; a failure here is logged, not fatal (SLD 10.4) |
| 7 | Log `PUBLISHED` (watermark, state query id), release the lease |

Failure handling: a failed `SUCCESS` flag, or any exception, logs `FAILED` with the stage, the exception text and the tail of `STDOUT`, revokes a dangling build-schema grant, and releases the lease. Nothing published changes. `failure_class` is `source` for a freeze failure and `unclassified` for a failed build; classifying source against transform from the failing test is part of S3.

`p3_publish.sql` exercises: first publication, "nothing new" skip, a new batch, "locked" skip, "stale upstream" skip, the CRM unit under its own role, and the resulting run-control state. S3 (failure signalling) follows, injecting failures into this procedure.

Not covered yet (S8): two units running at the same time; (S3): failures.

## Result (2026-10-06, `evidence/P3_publish_20261006.csv`): all 17 cases with an expectation PASS

| Case | Observed |
|---|---|
| P3.A1 to A3 | First call publishes ERP (`PUBLISHED`); log has `STARTED` then `PUBLISHED`; the published watermark equals the raw ERP landing watermark |
| P3.A5, B1, B2 | Lease free after a run; an immediate second call is `SKIPPED:nothing_new`; lease free after a skipped run |
| P3.C1 to C3 | New batch: publishes again; consumer reads 8 current orders; the email is masked after a procedure publish (S9f fix holds) |
| P3.D1 to D4 | Another run holds the lease: `SKIPPED:locked`, not queued; the holder is unchanged; its release works |
| P3.E1, E2 | Upstream older than tolerance: `SKIPPED:stale_upstream`; tolerance restored: the waiting batch publishes (10 orders) |
| P3.F1, F2 | The CRM unit publishes under `SVC_SILVER_CRM` (target `prod_crm`); consumer reads 2 contacts |
| P3.G1 | `silver.erp`: 3 `PUBLISHED`, 3 `STARTED`, 3 `SKIPPED`; `silver.crm`: 1 each, plus `DEPLOYED` |

**Observed (bug in the procedure, fixed):** P3.A4 recorded `canonical_ok = false` with "Boolean value '<query id>' is not recognized". The canonical compile ran (`WRITEBACK = FALSE` is accepted syntax; its query id was recorded) but the procedure read the success flag from the wrong statement: `LAST_QUERY_ID()` after capturing the query id pointed at the `SELECT last_query_id()` itself. The fix reads `RESULT_SCAN` of the saved query id. This is a reminder for S3: read the result of an `EXECUTE DBT PROJECT` immediately, or by its saved query id. `p3b_canonical.sql` re-runs and also tries `SYSTEM$LOCATE_DBT_ARTIFACTS` on that id.

**Observed (design):**

- `EXECUTE DBT PROJECT` run inside a caller's-rights procedure, with the result read by `RESULT_SCAN(LAST_QUERY_ID())` after `EXECUTE IMMEDIATE`, works for `run-operation` and `build` (steps 3 and 4 passed and the data was correct).
- A skip logs `SKIPPED` with a reason in `detail`, never `STARTED`, so run control separates skipped runs from attempted ones.
- `silver.ops.publish_unit` published two different units under two different roles with the same code, driven only by `units.selector` and `units.dbt_target`.

### p3b_canonical.sql (2026-10-06, `evidence/P3b_canonical_20261006.csv`): all PASS

- P3b.01, .02: after the fix, a new batch publishes and the canonical compile is recorded as ok (`canonical_ok = true`).
- P3b.03: the state query id is recorded in the `PUBLISHED` event.
- **P3b.04: `SYSTEM$LOCATE_DBT_ARTIFACTS(<query id>)` returns `snow://dbt/SILVER.OPS.SILVER_LAYER/results/query_id_<query id>/`**, a stage path CI can read `manifest.json` from for `state:modified` and `--defer` (SLD 3.2). It was called by the unit service role. Reading the artifacts from that path, and `--defer` against it, belong to S6.
