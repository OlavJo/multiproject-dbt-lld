# S3: failure signalling from `EXECUTE DBT PROJECT`

**Status:** **complete** (2026-10-06). Parts A and B1 (`evidence/S3_partA_B1_20261006.csv`), B2 and B3 (`evidence/S3b_20261006.csv`), attribution (`evidence/S3c_20261006.csv`).

## Question

SLD 3.1 and 10.4: `EXECUTE DBT PROJECT` is documented to complete and return `FALSE` in its success column when dbt fails, instead of raising. The publish procedure must read that result before each next step. Is the result reliable for `build`, `run-operation`, `compile` and `source freshness`; for test failures, warehouse errors and compile errors; and does the procedure then fail safe: nothing published, lease released, `FAILED` logged with enough to attribute the failure to ingestion or to the stewards (SLD 4.3, 8)?

Phase 0 observed that the result has three columns (`SUCCESS`, `EXCEPTION`, `STDOUT`), that `EXCEPTION` is the string `'None'` on success, and that there is no `OUTPUT_ARCHIVE_URL`.

## Method

**Part A (dbt level)** uses the helper `spike_lab.evidence.run_dbt`, which runs one call, catches anything it raises, and records whether it raised or returned, the success flag, the exception text and the tail of `STDOUT`. Failures are injected into `dbt/silver` through `--vars '{inject_failure: <kind>}'` (the injected models and tests are disabled otherwise):

| Case | Failure |
|---|---|
| A01 | none (baseline build) |
| A02 | a model fails in the warehouse (`1/0`) |
| A03 | an output test at `error` severity fails |
| A04 | a test at `warn` severity fails (expected: success, warning only) |
| A05, A11 | a jinja compile error (build and compile) |
| A06 | the selector does not exist |
| A07, A08, A09 | `run-operation`: the macro raises; the macro does not exist; the clone fails in the warehouse |
| A10, A12 | `compile` and `source freshness` succeed |
| A13 | not a dbt command |

**Part B (procedure level)** causes failures in raw, as they happen in production, and checks the procedure's reaction and recovery:

| Case | Cause | Expected |
|---|---|---|
| B1 | a null key lands: a **source test** fails | `FAILED:build`; published data, lease, masking unchanged; the log names the test |
| B2 | a raw table is missing: the **freeze** fails | `FAILED:freeze` |
| B3 | a raw column is renamed (schema drift): the **build** fails on a model | `FAILED:build` |

After each, the raw fault is repaired, a new batch lands, and the procedure publishes again.

Findings from B feed the classification of `failure_class` (source or transform) from the failing node.

## Run 1 (2026-10-06): stopped at B2, script defect

Part A and B1 ran. B2 stopped on `ALTER TABLE raw.erp.orders RENAME TO orders_x`: **`RENAME TO` resolves an unqualified new name against the session's current database, and the spike sessions have none** (`Cannot perform CREATE TABLE. This session does not have a current database`). Nothing was renamed. Rule for the LLD's scripts: qualify every rename target, as with `INFORMATION_SCHEMA` functions. Fixed in `s03_failure_signalling.sql`; `s03b_procedure_faults.sql` runs B2, B3 and the closing checks.

## Result, Part A and B1 (2026-10-06, `evidence/S3_partA_B1_20261006.csv`)

**Observed: `EXECUTE DBT PROJECT` raises on a dbt failure on this runtime; it does not return `FALSE`.** In every failing case the statement itself failed, with dbt's output in the error text. The helper marks those `FAIL` only because it expected a returned `FALSE`; they are findings, not defects. This contradicts SLD 3.1 ("failure is returned, not raised").

| Case | Failure | Outcome |
|---|---|---|
| A01 | none (build) | returned `success=true` |
| A02 | model fails in the warehouse | **raised**: `DBT job failed: 1 model(s) failed out of 14 total ... First error in model 'inj_sql_error' ... Division by zero` |
| A03 | output test at `error` | **raised**: `[ERROR]: in test inj_output_test_error ... Got 12 results, configured to fail if != 0 ... PASS=13 ERROR=1` |
| A04 | test at `warn` | returned `success=true` (the warning does not fail the call) |
| A05, A11 | jinja compile error (build, compile) | **raised**: `'s3_undefined_macro' is undefined` (as a model failure in build; as `Runtime Error` in compile) |
| A06 | selector does not exist | **raised**: `Could not find selector named unit_nope, expected one of ['unit_erp', 'unit_crm']` |
| A07 | `run-operation`: the macro raises | **raised**: `First error in macro 'freeze_sources' ... no tables declared for source nope_raw` |
| A08 | `run-operation`: macro missing | **raised**: `dbt could not find a macro with the name 'no_such_macro'` |
| A09 | `run-operation`: clone fails in the warehouse | **raised**: `000707 (02000): Time travel data is not available for table ACCOUNTS ...` |
| A10 | `compile` | returned `success=true` |
| A12 | `source freshness` (live raw source, `loaded_at_query` on the landing records) | returned `success=true` |
| A13 | not a dbt command | **raised**: `DBT command nonsense is not supported.` |

Every raised message ends with "Run `select system$get_dbt_log('<query id>')` for more details", except the unsupported-command one.

**Observed (procedure, B1):** a null key landing makes the source test fail; the procedure reports `FAILED:build` (B10), the published data is unchanged (B11), the lease is released (B12), the consumer still reads masked PII from the last good version (B16), and after the bad row is removed and a new batch lands the unit recovers (B17). The error text names the failing test, `in test source_not_null_erp_frozen_orders_order_id ... Got 1 result ... PASS=8 ERROR=1 SKIP=4`: **source tests run first and the four dependent nodes are skipped**, as SLD 8 describes ("gating is native"). The `FAILED` event recorded `build / unclassified`, and its STDOUT tail was empty, because the procedure only read the success flag path; the information was in the exception text.

**Design effect:**

1. The publish procedure must treat the raise as the normal failure path (the `WHEN OTHER` handler), with the returned `SUCCESS = FALSE` as a second defence, not the other way round. SLD 3.1 and 10.4 are to be corrected.
2. Failures are attributable from the error text: `in test source_*` is a source failure (ingestion), any other test or `in model` is a transform failure (stewards); the freeze stage is ingestion's. `setup/08` now classifies this way and fetches the dbt log with `SYSTEM$GET_DBT_LOG(<query id from the error>)`. `s03c_attribution.sql` verifies it.
3. A raw schema change that breaks a base view is a build failure at a model, so by the SLD's rule (where the failing test sits) it is classed as transform. The owner who must act is still ingestion; the LLD may want a drift check among the source tests.
4. `source freshness` and `compile` are usable from the procedure with the same raised-or-returned handling.

## Result, B2, B3 and closing checks (`evidence/S3b_20261006.csv`)

- **B2, a raw table is missing: `FAILED:freeze` (S3.B20).** The raised text names the table: `First error in macro 'freeze_sources': ... Object 'RAW.ERP.ORDERS' does not exist or not authorized`. Published data unchanged (B21), lease free (B22), logged `freeze / source` (B23). After the table is restored and a new batch lands, the unit publishes (B25).
- **B3, a raw column is renamed (schema drift): `FAILED:build` (S3.B30).** Published data unchanged (B31), lease free (B32). Logged `build / unclassified` and an empty STDOUT tail (B33, B34): this run used the procedure **before** the attribution update of `setup/08`; `s03c_attribution.sql` repeats it with the update. The unit recovers after the column is restored (B35).
- **Run control after three failures and recoveries (B40):** each failed run appears as `STARTED` then `FAILED:<stage>`; each recovery as `STARTED` then `PUBLISHED`. No run is left as an unterminated `STARTED`.
- **B41 FAIL was a script defect, not a finding:** the stale-run view `unit_stale` is a steward view, and the unit role has no grant on it (`Object ... does not exist or not authorized`). The script now runs that check as the steward.

Remaining for S3: `s03c_attribution.sql` after re-running `setup/08` (classification and the dbt log fetch).

## Result, attribution (`evidence/S3c_20261006.csv`, after the `setup/08` update): all PASS

| Fault | Logged `stage / class` | dbt log fetched |
|---|---|---|
| B1 a null key lands (source test fails) | `build / source` | true |
| B2 a raw table is missing (freeze fails) | `freeze / source` | true |
| B3 a raw column is renamed (a base view breaks the build) | `build / transform` | true |

Each failed with nothing published, the lease released and the next batch recovering the unit (S3c.B10 to B35). `S3c.90` shows the three events in order.

**Note on the log fetch.** `SYSTEM$GET_DBT_LOG(<query id>)` returns the tail of dbt's **debug** log (timestamps, connection closes, artifact writes), which does not by itself name the failure; the **exception text** does (the failing test or model, the counts, the database error). The `FAILED` event therefore keeps both: the first 4,000 characters of the exception, and the query id (`dbt_query_id`) from which the full log can be fetched on demand.

## Conclusions for the design

1. **`EXECUTE DBT PROJECT` raises on a dbt failure** (not documented: SLD 3.1, 10.4 and the Overview are to be corrected). The publish procedure's failure path is a handler on the raised error, with the returned success flag as a second check. Warn-severity test failures, `compile` and `source freshness` return success.
2. **The procedure fails safe in every tested failure:** nothing published changes, the lease is released, the failure is logged with stage, class and the error text, and the next run recovers from the last good state.
3. **Failures are attributable from the error text:** a failing source test or the freeze is ingestion's; other tests and models are the stewards'. A schema drift in raw surfaces as a model failure (`transform`), so the LLD should add a drift check to the source tests if ingestion is to own it.
4. **Scripting rules for the LLD:** qualify `RENAME TO` targets; read `RESULT_SCAN` of a saved query id, not `LAST_QUERY_ID()` after another statement; do not rely on `RESULT_SCAN` for `SYSTEM$` function results.
