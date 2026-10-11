# Spike log

Chronological record of runs, findings and decisions. Newest entries at the bottom. Each finding is marked **Observed** (evidence row committed) or **Documented only**.

## 2026-10-05: Kick-off

- Engineering Advisory Board approved the spikes and the Low Level Design, based on Overview v1.3 and SLD v1.3.
- Agreed scope limits: production-volume behaviour and anything requiring a second account (replication, failover) are out of scope for the trial account.
- Environment: Snowflake trial account, Enterprise edition, ACCOUNTADMIN available for setup. Free GitHub repository for all scripts and evidence.
- Ground rules adopted (see README): role discipline, secondary roles disabled, evidence rows for every observation.

**Documented only (to be confirmed in Phase 0):**

- The `2026_06` behaviour change bundle, which makes dbt project objects live-version, is documented as enabled by default (Snowflake release note BCR-2362).
- Snowflake's supported dbt versions page lists dbt Core 1.12.3 alongside 1.11.11. If confirmed by `SYSTEM$SUPPORTED_DBT_VERSIONS()` (case P0.06), the Overview's statement that `latest_version_pointer` is unavailable on the pinned runtime (Overview 8.2) becomes a choice of pin rather than a platform limit.

## 2026-10-05: Phase 0, first run of `setup/00`

- Statements before the probe self-test succeeded (warehouse, resource monitor, evidence table, `PROBE` procedure).
- **Observed:** `SET <var> = <function call>` fails with `Unsupported feature 'assignment from non-constant source expression'`. Session variables must be set from a constant or a subquery: `SET run_id = (SELECT UUID_STRING())`. All scripts corrected. No design impact; noted for the LLD's scripting conventions.

## 2026-10-05: Phase 0, `setup/00` and `setup/01` results

Account: Azure Australia East (`AZURE_AUSTRALIAEAST`), Snowflake release 10.35.101, Enterprise edition.

**Observed:**

- Probe self-test P0.00a to P0.00c: all PASS, secondary roles empty. The error text in P0.00b reads "Your **primary** role SYSADMIN must have at least one privilege...", showing authorisation by the primary role alone.
- P0.05/P0.06, `SYSTEM$SUPPORTED_DBT_VERSIONS()`: dbt Core 1.9.4, 1.10.15, 1.11.11, **1.12.3**; dbt Fusion 2.0.0 and previews 2.0.0-preview, -preview.175, -preview.186, -preview.210. 1.11.11 (the HLD pin) is available. **1.12.3 is also available**, so the Overview 8.2 statement that `latest_version_pointer` is unavailable is a consequence of the pin, not a platform limit. Decision needed before the LLD fixes the runtime.
- P0.07, `DEFAULT_DBT_VERSION` = 1.9.4. Confirms Overview 2 and SLD 3.1: unpinned executions run 1.9.4.
- P0.08, the spike user's `DEFAULT_SECONDARY_ROLES` = `["ALL"]`. Confirms ground rule 3 is necessary: without `USE SECONDARY ROLES NONE`, privilege results would reflect the union of all granted roles. Recommendation for the LLD: service users and CI users set `DEFAULT_SECONDARY_ROLES = ()`.
- P0.09 to P0.11: Time Travel retention above 1 day, masking policies, and `ACCESS_HISTORY` (79 rows) all available (Enterprise).
- P0.12: semantic views available (`SHOW SEMANTIC VIEWS` runs; none exist yet).

**Probe defect (not a finding):** P0.04 returned `ERROR: String 'ENABLED' is too long and would be truncated` when run through `PROBE`. Run directly in a worksheet, `SYSTEM$BEHAVIOR_CHANGE_BUNDLE_STATUS('2026_06')` returned **`ENABLED`** (observed). A probe change converting through `VARIANT` did not help (rerun of `01` failed the same way) and was reverted. Recording it outside the procedure with `INSERT ... SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))` then failed with `DML operation to table SPIKE_LAB.EVIDENCE.OBSERVATION failed on column OBSERVED with error: String 'ENABLED' is too long and would be truncated` (observed). The failure is therefore in reading this function's result back through `RESULT_SCAN`, not in the procedure; the probe also uses `RESULT_SCAN`. Working hypothesis, to be confirmed by P0.04a (`DESCRIBE RESULT`): the function's result column is declared with a short string length that `RESULT_SCAN` enforces. P0.04 is now recorded by calling the function inline in the `INSERT`. Practical rule for later scripts: do not read `SYSTEM$` function results through `RESULT_SCAN`. Live version is also checked independently in P0.21.

## 2026-10-05: Phase 0, P0.04 resolved, `setup/02` and `setup/03`

**Observed:**

- P0.04 (inline, outside `RESULT_SCAN`): `2026_06` bundle **ENABLED**. PASS.
- P0.04a: `DESCRIBE RESULT` of `SYSTEM$BEHAVIOR_CHANGE_BUNDLE_STATUS` declares the result column as **`VARCHAR(1)`** while returning `ENABLED`. This confirms the cause of the earlier failures: `RESULT_SCAN` enforces the declared length. LLD scripting convention: do not read `SYSTEM$` function results through `RESULT_SCAN`; call them inline.
- `setup/02`: a database role receives `USAGE` on its own database automatically at creation (`SHOW GRANTS TO DATABASE ROLE silver.reader` lists an implicit `USAGE` with empty `granted_by`, created before the explicit grant). The explicit grant in `02_roles.sql` is redundant.
- `setup/02`: the account timezone is the default `America/Los_Angeles` (`-0700` in `created_on`). Run control is unaffected (UTC `timestamp_ntz` from `SYSDATE()`). LLD environment setup: set `TIMEZONE = 'UTC'` at account level or for service users.
- `setup/03`: `CREATE GIT REPOSITORY` with origin `https://github.com/OlavJo/dbt-spikes-2026.git` was rejected by an API integration whose `API_ALLOWED_PREFIXES` was `https://github.com/OlavJo/dbt-spikes-2026` ("Location ... is not allowed by integration"). Allowed prefixes match whole path segments, so a single-repository integration must name the URL including `.git`. Script corrected.
- `setup/03` rerun with the corrected prefix succeeded: the Git repository object was created and fetched. This confirms that the prefix must include `.git`.
- P0.14 first run recorded FAIL because the probe captured `SHOW SECRETS`' first column (`created_on`) instead of the name; script defect, corrected to record name and owner.
- P0.13 and P0.14 PASS: the private repository is readable from Snowflake through the PAT secret, and the secret is owned by `SILVER_STEWARD`.
- `03` changed to `CREATE SECRET IF NOT EXISTS`, so a rerun cannot overwrite the token with the placeholder; rotation is by `ALTER SECRET ... SET PASSWORD`. LLD note: secret creation and rotation belong in a separate, never-rerun-by-default step from the rest of environment setup.

## 2026-10-05: Phase 0, `setup/04`

- **Observed:** referencing `$4` in the result of `EXECUTE DBT PROJECT` fails (`invalid identifier '$4'`), so the result has fewer than the four documented output columns (`0|1 Success`, `EXCEPTION`, `STDOUT`, `OUTPUT_ARCHIVE_URL`). Evidence rows now record the whole result row; the actual column set will be read from P0.22's `detail`. Relevant to S3 (the publish procedure must read the success flag reliably).
- `04` rerun after the fix: all cases PASS (run at 2026-10-05 04:02 to 04:03 UTC).
  - P0.20: dbt project object `SPIKE_LAB.HELLO.HELLO` created from the private Git repository, pinned `DBT_VERSION = '1.11.11'`.
  - P0.21: `default_version = LIVE`. **New project objects are live-version on this account** (SLD 3.2 prerequisite met).
  - P0.22: `EXECUTE DBT PROJECT ... ARGS = 'build'` succeeded.
  - P0.23: the model recorded `dbt_version = 1.11.11`. The object-level pin is honoured.
  - P0.24: the model was built under `SILVER_STEWARD`, the role in `profiles.yml`.
  - P0.25/P0.26: an execution with `DBT_VERSION = '1.12.3'` succeeded and the model recorded `1.12.3`. **A per-execution runtime override works without altering the object's pin.** Design consequence (SLD 3.3): CI can test a candidate runtime (a newer Core or Fusion) against the production project object by passing `DBT_VERSION` on the execution; the object's pin changes only at release.

**Phase 0 complete.** All prerequisites for Phase 1 are observed.
- **Observed: `EXECUTE DBT PROJECT` result shape** (P0.22 `detail:result`, successful build):
  - Three columns: **`SUCCESS`** (boolean), **`EXCEPTION`**, **`STDOUT`**. The documented `OUTPUT_ARCHIVE_URL` is absent, and the success column is named `SUCCESS`, not `0|1 Success`.
  - On success, `EXCEPTION` is the **string `'None'`**, not SQL `NULL`.
  - Design consequence (SLD 3.1, 10.4, spike S3): the publish procedure decides on `SUCCESS` only, and must not test `EXCEPTION IS NULL`. To be confirmed for failing runs in S3. Column access should be by name, not position.
  - `STDOUT` shows the managed runtime: **dbt-core 1.11.11 with dbt-snowflake 1.11.5**. The LLD should pin and record the adapter version alongside the core version.
- **Evidence committed:** `evidence/P0_20261005.csv` (all Phase 0 rows, including the failed runs referred to above). Further observations from its `DETAIL` column:
  - **Deployment traceability (P0.21).** `SHOW DBT PROJECTS` records `last_deployed_from` with the Git branch, **commit hash**, stage URL, timestamp and deploying user, plus `dbt_version` and `dbt_snowflake_version`. The `DEPLOYED` event in run control (SLD 12.2, `detail: commit`) can be populated from this rather than from CI variables.
  - **A runtime switch forces a full re-parse (P0.25).** The 1.12.3 execution logged `Unable to do partial parsing because of a version mismatch`, confirming SLD 3.2's statement that changing the dbt version invalidates partial-parse state. It also ran with `dbt-snowflake 1.12.0`. Because writeback defaults to `TRUE`, a trial execution on another runtime writes its artifacts back to the live version, and the next run on the pinned runtime re-parses in full. LLD consequence: CI runtime trials should use `WRITEBACK = FALSE` or a separate project object.
  - **Runtime warning on 1.12.3 (P0.25).** dbt 1.12.3 warns `EnvironmentVariableNamespaceDeprecation` about `DBT_ENGINE_MANAGE_STATE`, an environment variable set by Snowflake's managed runtime, not by us. It is harmless, but it is noise in every 1.12 run log, and would trip any policy that treats deprecation warnings as errors. It also logs `State adapter: dbt-state v0.0.0 is disabled`.

## 2026-10-05: S1 run 1

Evidence: `evidence/S1_20261005.csv`. Full write-up in `spikes/S01_view_binding/README.md`.

- **Observed: plain views PASS on every case.** Bare same-schema identifiers bind at query time in the view's own schema, survive `SWAP WITH` and rebind under schema `CLONE`. SLD 10.5 confirmed; SLD 10.6 contingency not needed.
- **Observed: semantic views FAIL.** A bare table name in `CREATE SEMANTIC VIEW` is resolved at creation against the **session's** current schema and stored fully qualified (`SILVER.S1_OTHER.T`). SLD 10.7 rule 2 cannot apply to semantic views.
- **Observed: `CREATE SCHEMA` switches the session's current schema** to the new schema; the S1 script's decoy was therefore only in force for Part A.
- Script changed for run 2: decoy re-asserted after every `CREATE SCHEMA`; Part E added to test semantic views that reference the **published** table name (candidate fix) and the new-column limitation.

## 2026-10-05: S1 run 2, S1 complete

Evidence: `evidence/S1_20261005_2.csv`.

- **Observed:** plain-view results identical to run 1 (all PASS).
- **Observed:** with the decoy session schema in force throughout, S1.23 and S1.31 read `OTHER`, confirming that semantic views bind bare table names to the **session** schema at creation.
- **Observed (Part E):** a semantic view in the build schema that references the **published** table name publishes atomically with the swap (S1.41 `NEWER` before, S1.42 `E_NEW` after), stored as `SILVER.S1_PUB.T`.
- **Observed:** semantic view columns are validated at creation (`invalid identifier 'EXTRA'`, S1.44), so a published-name semantic view cannot use a column that is new in the same build.

**S1 conclusion.** SLD 10.5 confirmed for plain views; 10.6 contingency not needed. SLD 10.7 rule 2 to be revised: semantic views reference published names; new-column changes to semantic views lag one publication or are applied after the swap.

## 2026-10-05: S2 run 1

Evidence: `evidence/S2_20261005.csv`. Full write-up in `spikes/S02_swap_grants/README.md`.

- **Observed: schema-level `USAGE` moves with the schema object under `SWAP WITH`, not with the name.** A plain swap locks consumers out of the published name and exposes the previous version under the build name. The HLD's preferred reading is refuted.
- **Observed: the SLD 10.7 rule 5 fallback works.** Grant `USAGE` on the build schema, swap, revoke from the new build schema: consumers read the new version and lose build access. This becomes the publish procedure's swap step.
- **Observed: object-level grants are copied by schema clone** and internal objects stay invisible.
- **Unproven:** the clone of a managed-access schema showed no `MANAGED ACCESS` option. Run 2 adds a control, checks the published schema after the swap, and tests variant D (`ENABLE MANAGED ACCESS` on the build schema plus the grant sequence).

## 2026-10-05: S2 run 2

Evidence: `evidence/S2_20261005_2.csv`.

- Variants A to C repeated run 1 exactly.
- **Observed: a schema clone does not inherit managed access** (S2.29 control: source is managed access; S2.30: clone is not). After the first clone-and-swap publication, the **published schema is no longer managed access** (S2.34).
- **Observed: `ALTER SCHEMA ... ENABLE MANAGED ACCESS` requires `MANAGE GRANTS` on the account**, even for the schema owner (S2.40). Not acceptable for a unit service role.
- **Observed:** the grant, swap, revoke sequence works on managed-access schemas too (S2.43 to S2.45).
- Variant E added: build schema created as a managed-access clone in one statement (`CREATE SCHEMA ... CLONE ... WITH MANAGED ACCESS`, and the alternative clause order), which the Snowflake privilege table suggests exists.

## 2026-10-05: S2 variant E, S2 complete

Evidence: `evidence/S2E_20261005.csv`.

- **Observed:** `CREATE OR REPLACE SCHEMA <build> CLONE <published> WITH MANAGED ACCESS` is accepted from the unit service role without `MANAGE GRANTS`, and the build schema is managed access (S2.50, S2.51). The other clause order is a syntax error (S2.52).
- **Observed:** after the grant, swap, revoke sequence, the published schema is still managed access, consumers read the new version, and the build schema and internal objects stay inaccessible (S2.54 to S2.57).
- A full rerun of S2 in the same session added duplicate A to D rows under a separate run id; harmless.

**S2 conclusion.** Publish step: clone `WITH MANAGED ACCESS`, build, grant `USAGE` on the build schema, swap, revoke `USAGE` from the new build schema. Object grants travel with clone and swap. Managed access is preserved only by the `WITH MANAGED ACCESS` clone.

## 2026-10-05: `setup/05_governance.sql`

- **Observed:** `CREATE TAG ... PROPAGATE = ON_DATA_MOVEMENT` fails with `Operate PROPAGATE property requires APPLY TAG ON ACCOUNT privilege`, even for the role creating and owning the tag. Automatic tag propagation is therefore a governance-team capability (account-level `APPLY TAG`), not something a unit or steward role can configure. Script corrected to grant `APPLY TAG ON ACCOUNT` to `GOVERNANCE_ADMIN`.
- `setup/05` rerun succeeded: `PII` (`propagate = NONE`) and `PII_AUTO` (`propagate = ON_DATA_MOVEMENT`), both owned by `GOVERNANCE_ADMIN`. Evidence: `evidence/P0_05_governance_20261005.csv`.

## 2026-10-05: S12 run 1

Evidence: `evidence/S12_20261005.csv`. Full write-up in `spikes/S12_unit_lease/README.md`.

- **Observed: all 27 cases PASS.** Lease acquire and release semantics, expiry and takeover, holder-only release, privilege boundaries, stale `STARTED` detection, and the gate including `DEPLOYED`.
- **Observed: 5 races x 20 contenders via `ASYNC` child jobs: exactly one winner per race, and the winner held the lease.** Attempts per race spread over at most 7.3 s. Because timestamps are taken after each attempt, overlap of the lease `UPDATE` statements in query history is still to be recorded as direct evidence of concurrency (S12.34).
- **Observed:** Snowflake Scripting `ASYNC (CALL ...)` in a `FOR` loop with `AWAIT ALL`, and `CALL ... INTO :var`, work in caller's-rights procedures.
- **Observed (S12.34, `s12_concurrency_check.sql`):** query history holds exactly the expected 105 lease `UPDATE` statements, and up to **20 were in progress at the same moment**. The races were fully concurrent, and each still had exactly one winner. **S12 complete.**
- Note: `INFORMATION_SCHEMA` table functions fail with `Invalid identifier INFORMATION_SCHEMA.QUERY_HISTORY` when the session has no current database; qualify them with a database.

## 2026-10-05: S9 visibility half, run 1

Evidence: `evidence/S9_20261005.csv`. Full write-up in `spikes/S09_frozen_inputs/README.md`.

- **Observed: all cases PASS.**
- **Observed: `CLONE ... AT (TIMESTAMP => <TIMESTAMP_NTZ>)` interprets the value as UTC regardless of session timezone** (3 rows under `America/Los_Angeles` and under UTC). The freeze can use UTC NTZ watermarks directly.
- **Observed:** frozen inputs are transient, hold exactly the rows as of the watermark, carry raw's tags and masking, and have no grants beyond ownership.
- **Observed: SLD 6.3 premise confirmed.** A CTAS does not carry a plain tag, and consumers then read the PII in clear.
- **Observed: automatic tag propagation (`PROPAGATE = ON_DATA_MOVEMENT`) tags and masks a CTAS target with no post-hook.** Candidate simplification of SLD 6.3; follow-up S9b covers incremental DML, expressions, joins and conflicts.

## 2026-10-05: S9b, limits of tag propagation

Evidence: `evidence/S9b_20261005.csv`.

- **Observed:** `PROPAGATE = ON_DATA_MOVEMENT` tags derived columns for CTAS, `MERGE` (insert and update), `INSERT ... SELECT`, DDL-created targets and joins; tags present immediately (identical after 10 s); consumer masked in every string case.
- **Observed:** propagation follows lineage, not meaning: `lower`, `sha2`, `left`, `coalesce`, concatenation, `length`, `count(distinct)` and `max` all carry the tag. Two values of one tag combine to `CONFLICT`, still masked.
- **Observed: a tagged NUMBER column (`length(phone)`) is returned in clear**, because the tag's only masking policy is for strings.
- Design effect: propagation replaces the SLD 6.3 post-hook; each classification tag needs a masking policy per data type; declassification of over-tagged derived columns becomes the explicit, reviewed act (fails closed). Open: whether a manual tag override on a target column survives later `MERGE` statements.

## 2026-10-06: S9c run 1 (storage), S9d (tag override)

**Observed (S9c):** `INFORMATION_SCHEMA.TABLE_STORAGE_METRICS` returned no rows for any role (raw and Silver, via the owning roles), so the per-cycle snapshots were empty. A transient clone takes the retention period of the **schema it is created in**, not the source's (S9c.00: `retention_time` 0 in `S9C_RET0`, 1 in `S9C_RET1`). Retained storage is to be read from `ACCOUNT_USAGE.TABLE_STORAGE_METRICS` (latency up to ~90 minutes; `s09c_read_metrics.sql`, 2 to 24 hours after the run). Design effect so far: the SLD 7.4 mitigation "short retention on Silver schemas" is workable, because a schema's retention period applies to the frozen clones in it.

**Observed (S9d, `evidence/S9d_20261006.csv`):**

- A manual `SET TAG` on a propagated tag changes its value (`MANUAL`), survives `MERGE`, `INSERT ... SELECT` and a managed-access schema clone, and is lost on full-refresh CTAS. It does not unmask: the masking policy is attached to the tag.
- `UNSET TAG` is not durable: the next `MERGE` re-applies the propagated tag. The consumer saw clear data between the UNSET and the next MERGE.
- Design effect (SLD 6.3): declassification cannot be an UNSET. S9e tests a value-aware masking policy (`SYSTEM$GET_TAG_ON_CURRENT_COLUMN`) with a reserved tag value.

## 2026-10-06: S9e, declassification mechanism

Evidence: `evidence/S9e_20261006.csv`. Write-up in `spikes/S09_frozen_inputs/README.md`.

- **Observed: all 11 cases PASS.** A value-aware masking policy (`SYSTEM$GET_TAG_ON_CURRENT_COLUMN` = `declassified`) on a propagating tag unmasks a derived column. The tag value survives `MERGE`, `INSERT ... SELECT` and the managed-access schema clone, and a full-refresh `CREATE OR REPLACE ... AS SELECT` reverts it to masked (fails closed). A role without `APPLY` on the tag cannot set it.
- **SLD 6.3 revised:** propagation replaces the post-hook for classification; declassification is an explicit, reviewed tag value, re-applied after any rebuild; governance owns the tag and the policy.
- **S9 status:** visibility, S9b, S9d and S9e complete. Only the S9c metrics read (ACCOUNT_USAGE) remains.

## 2026-10-06: Phase 2 started: shared Silver project

Decisions (with the user): dbt Core 1.12.3 for the Silver project, staying on Core; HLD documents updated after the spikes; project at `dbt/silver`; scripts run by the user, results returned to Claude.

Built (not yet run in Snowflake): `dbt/silver/`, `setup/06_silver_prereqs.sql`, `setup/07_silver_project.sql`, `spikes/P2_smoke/`. See `spikes/P2_smoke/README.md`.

**Observed offline (dbt Core 1.12.3, dbt-snowflake 1.12.0, `dbt parse` and `compile --no-populate-cache`):**

- Project macros are **not available when a source's `schema:` property is rendered** (`'unit_schema' is undefined`). The schema redirection for frozen-input sources must live in the `source()` override (compile time), not in the source YAML. LLD note for S6 and SLD 10.4.
- `ref`/`source` overrides compile as designed: bare identifiers for same-schema references from views, qualified names elsewhere, source tests redirected to `<unit>__build` while a unit is published and to the published schema otherwise.

## 2026-10-06: Phase 2, `setup/06`

Evidence: `evidence/P2_setup06_20261006.csv`. **Observed:** all 6 checks PASS (77 statements). The ERP service role reads the landing-complete view (2 batches) and raw accounts unmasked; ERP orders carry 3 versions of order 1 (original plus one per batch); the CRM role reads raw contacts and cannot read ERP raw orders; `unit_status` lists 7 units (raw and silver).

## 2026-10-06: Phase 2 smoke test (`setup/07`, `p2_smoke.sql`)

Evidence: `evidence/P2_smoke_20261006.csv` (32 cases, 2 rounds). **30 PASS, 2 FAIL** (the same case in each round). Write-up in `spikes/P2_smoke/README.md`.

- **Observed:** `setup/07`: project object created from Git `main` and live-version; both `GRANT USAGE ON DBT PROJECT` statements succeeded (privilege name confirmed).
- **Observed: `EXECUTE IMMEDIATE` runs `EXECUTE DBT PROJECT` with dynamically built `ARGS`, and `RESULT_SCAN(LAST_QUERY_ID())` reads its result** (P2.S1.01, .05): the first SQL-only path for the publish procedure's dbt calls.
- **Observed: `--target prod_erp` runs the project under the unit's service role** (objects were built and swapped by `SVC_SILVER_ERP`, which owns both schemas); a unit role can execute the shared project object.
- **Observed: the whole publish sequence works as plain statements:** clone `WITH MANAGED ACCESS`, `run-operation freeze_sources` (4 and 6 rows round 1, 6 and 9 round 2; transient), `dbt build --selector unit_erp` (source tests, models, output tests), grant/swap/revoke, consumer reads. The incremental merge worked on a table cloned from the published schema (round 2: 6 current rows, order 1 `SHIPPED`).
- **Observed: the S1 rule holds in a real dbt build:** the base view's DDL reads `from raw__orders` (bare), and the published view reads the swapped frozen input (9 rows after round 2).
- **Observed: consumers cannot read frozen inputs or the build schema** (P2.S*.14, .15).
- **Observed (FAIL, finding): PII was not masked in `erp_accounts`**: the consumer read `user1@example.com` (P2.S1.13, P2.S2.13). The table is built from a base view over a frozen input; every earlier propagation test went from tables. Follow-up S9f.

## 2026-10-06: S9f, tag propagation through views

Evidence: `evidence/S9f_20261006.csv`. Write-up in `spikes/S09_frozen_inputs/README.md`.

- **Observed:** `PROPAGATE = ON_DATA_MOVEMENT` does not cross a base view; the table built from the view carries no tag and the consumer reads clear PII. A tag created with **`PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT`** is carried by the view column and by a table built from the view, and the consumer reads masked values.
- **Design effect (SLD 6.3):** classification tags must use `ON_DEPENDENCY_AND_DATA_MOVEMENT` (base views are in every chain); declassification uses the S9e reserved value; a CTAS under the service role stores clear values, so CI verification of the tag on derived columns stays the safety net.
- **Spikes updated:** `setup/05` creates `PII_DEP`; `setup/06` tags the skeleton's raw column with it; `spikes/P2_smoke/p2_smoke_r3.sql` re-tags and republishes ERP to verify.

## 2026-10-06: Phase 2 smoke test, round 3 (fix confirmed)

Evidence: `evidence/P2_smoke_r3_20261006.csv`, `evidence/P0_05_governance_20261006.csv`.

- `setup/05` rerun: `PII_DEP` exists with `propagate = ON_DEPENDENCY_AND_DATA_MOVEMENT` (alongside `PII`, `PII_AUTO`, `PII_DECL`).
- **Observed: all 16 cases PASS.** After re-tagging the raw column with `PII_DEP`, a republish with no new batch (a deployment-style republish) gives a consumer read of `***MASKED***` in the materialised `erp_accounts` (P2.S3.13). Phase 2 plumbing is proven; the next step is the publish procedure.

## 2026-10-06: Phase 2, the publish procedure (`setup/08`, `p3_publish.sql`)

Evidence: `evidence/P3_publish_20261006.csv`. Write-up in `spikes/P3_publish/README.md`.

- **Observed: all 17 cases with an expectation PASS.** First publication through the procedure, `SKIPPED:nothing_new`, new batch, `SKIPPED:locked`, `SKIPPED:stale_upstream`, and the CRM unit under its own role and target. Masking holds after a procedure publish.
- **Observed: `EXECUTE DBT PROJECT` inside a caller's-rights procedure works** for `run-operation freeze_sources` and `build --selector`, with the result read by `RESULT_SCAN(LAST_QUERY_ID())` after `EXECUTE IMMEDIATE`. `WRITEBACK = FALSE` is accepted on `compile`.
- **Bug (mine) found:** the canonical compile's result was read from the wrong statement. Fixed in `setup/08`; `p3b_canonical.sql` verifies, and tries `SYSTEM$LOCATE_DBT_ARTIFACTS` on the recorded query id.

## 2026-10-06: Phase 2, canonical state (`p3b_canonical.sql`)

Evidence: `evidence/P3b_canonical_20261006.csv`. **Observed:** with the result read fixed, the canonical compile (`WRITEBACK = FALSE`) after the swap is recorded as ok, and `SYSTEM$LOCATE_DBT_ARTIFACTS(<state query id>)` returns the stage path `snow://dbt/SILVER.OPS.SILVER_LAYER/results/query_id_<id>/` (called by the unit service role). Reading the manifest from it and `--defer` are S6.

## 2026-10-06: S9c, retained storage read

Evidence: `evidence/S9c_20261006.csv`. Write-up in `spikes/S09_frozen_inputs/README.md`.

- **Observed:** after 6 cycles of churn and re-freeze (read about 3 hours later from `ACCOUNT_USAGE`), every frozen-clone version, live or replaced, in schemas with 1-day and 0-day retention, holds **0.0 MB** of its own storage. The cost sits on raw as Time Travel bytes of the rewritten partitions: 567 MB (5.8x the table) for scattered churn and 168 MB (1.8x) for append-like churn. `RETAINED_FOR_CLONE_BYTES` is 0 everywhere because raw's own 1-day Time Travel still covers the rewritten partitions.
- **Design effect (SLD 7.4):** frozen-input clones add no storage within raw's Time Travel period; a short retention on Silver schemas removes the remaining risk (a replaced clone outliving raw's retention) by construction. The window in which `RETAINED_FOR_CLONE_BYTES` could appear opens about a day after a run; an optional re-read at about 26 hours would show it for the 1-day schema.

## 2026-10-06: S3 run 1: Part A and B1 (script defect stopped B2)

Evidence: `evidence/S3_partA_B1_20261006.csv`. Write-up in `spikes/S03_failure_signalling/README.md`.

- **Observed: `EXECUTE DBT PROJECT` raises on a dbt failure; it does not return `FALSE`** (model warehouse error, test at `error`, compile error, missing selector, `run-operation` failures, unsupported command). Warn-severity test failures, `compile` and `source freshness` return `success=true`. The raised text carries dbt's output (the failing node, the counts) and a query id for `SYSTEM$GET_DBT_LOG`. **SLD 3.1 ("failure is returned, not raised") and 10.4 are to be corrected.**
- **Observed (B1):** the procedure handles the raise correctly (`FAILED:build`, published data unchanged, lease released, masking intact, recovery on the next batch); source tests run first and skip dependent nodes.
- **Attribution:** the error text names the failing test or model, so `failure_class` is derivable. `setup/08` now classifies (`in test source_*` and the freeze: source; other tests and models: transform) and fetches the dbt log by the query id in the error. Verified by `s03c_attribution.sql`.
- **Script defect:** B2 stopped on `ALTER TABLE ... RENAME TO orders_x` (the new name resolves against the session's current database; there is none). Rename targets must be qualified. Fixed; remaining cases in `s03b_procedure_faults.sql`.

## 2026-10-06: S3 run 2: B2, B3, closing checks (`s03b_procedure_faults.sql`)

Evidence: `evidence/S3b_20261006.csv`.

- **Observed:** a missing raw table makes the freeze fail with the table named in the raised text (`FAILED:freeze`, class `source`); a renamed raw column makes the build fail (`FAILED:build`). Both: published data unchanged, lease released, recovery on the next batch. Each failed run is `STARTED` then `FAILED`; no stale `STARTED`.
- B3 was classed `build / unclassified` because the attribution update of `setup/08` had not been applied yet; `s03c_attribution.sql` verifies it. B41 failed on a missing grant on the steward-only view `unit_stale` (script defect; fixed).

## 2026-10-06: S3 complete (`s03c_attribution.sql`)

Evidence: `evidence/S3c_20261006.csv`. **Observed: all PASS.** After the `setup/08` update the procedure classifies the three faults as `build / source` (failing source test), `freeze / source` (missing raw table) and `build / transform` (renamed column breaking a base view), and fetches the dbt log. Each failure: nothing published, lease released, recovery on the next batch.

**S3 conclusions** (full list in `spikes/S03_failure_signalling/README.md`): `EXECUTE DBT PROJECT` raises on a dbt failure (SLD 3.1 and 10.4 to be corrected); the raised text carries dbt's output and names the failing node; the procedure fails safe in every tested case; `SYSTEM$GET_DBT_LOG` returns the debug-log tail, so the exception text, not the log, is what attributes the failure.

## 2026-10-06: S8, concurrent units on one project object

Evidence: `evidence/S8_20261006.csv`, `evidence/S8_DE_detail_20261006.csv`, `evidence/S8_A_failures_20261006.csv`, `evidence/S8b_run1_20261006.csv`, `evidence/S8b_run2_20261006.csv`. Write-up in `spikes/S08_concurrent_units/README.md`.

- **Observed: two units published concurrently on one live-version project object, each as a task owned by its own service role** (runs overlapped; about 45 to 50 s each, the same as alone; up to 3 `EXECUTE DBT PROJECT` statements at once; distinct canonical state query ids; each unit's data correct).
- **Observed: a unit must run as its own service role.** A caller's-rights procedure creates the build schema owned by the caller's primary role, while dbt runs as the profile role: a SYSADMIN orchestrator that only inherits the unit roles failed at the freeze (safely). LLD decision: a task per unit, each owned by that unit's role, or one shared Silver service role owning every unit schema (which also permits one task graph).
- **Observed: a task is not the run's status**: tasks showed `SUCCEEDED` for publications that failed; monitoring must read run control.
- **Observed: partial parsing is per target path; changed `--vars` force a full re-parse in both directions** (evidence: the absence of the "Unable to do partial parsing" message).
- **Observed: `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET` is one pointer for the object** (the last unit to finish); per-unit canonical state is the query id in the `PUBLISHED` event.
- **Open:** one denial of `LOCATE_DBT_ARTIFACTS` (ERP role, an older CRM execution) is unexplained; two executions on one target path (the helper failed under `ASYNC`); a deployment during running units. Retested in `s08c` and `s08d`.

## 2026-10-07: S8 follow-ups (`s08c`, `s08d`, `s08e`)

Evidence: `evidence/S8c_20261007.csv`, `S8d_20261007.csv`, `S8e_20261007.csv`, `S8e_query_history_20261007.csv`.

- **Observed: `CREATE OR REPLACE DBT PROJECT` drops every grant on the object** (only the owner remains) **and makes the artifacts of all earlier executions unreachable** (`LOCATE_DBT_ARTIFACTS` denied for an execution before the redeploy, found for one after, denied again after a further redeploy). The earlier denial of `LOCATE_DBT_ARTIFACTS` was this, not role scoping.
- **Observed: a deployment during a running publication does not break it**: the redeploy overlapped the build and the canonical compile and the unit still published; its recorded state id belongs to the replaced object.
- **Observed: two executions on one target path both succeed** (no writeback message; partial-parse warning on one only). The per-unit paths of the design stay.
- **S8 conclusions** are listed in `spikes/S08_concurrent_units/README.md`. Remaining question: a deployment route that keeps grants and state (`s08f`).

## 2026-10-07: S4 built (not yet run); s08f fix

- **S4:** a third Source Entity unit `silver.s4` (CDC feed with a source ordering column and commit time; a full-load table), an incremental CDC history model keyed on `(order_id, source_seq)` that recomputes the validity of every key that received a change (late changes, redeliveries and deletes), a snapshot whose validity stamps come from the unit watermark (the freeze records it in `<unit>__build._freeze`; a `snowflake__snapshot_get_time` override reads it), generic history tests (`history_contiguous`, `one_open_version`, `current_matches_history`), `setup/09`, and `spikes/S04_history_snapshots/`. Parse and selector checks done offline (dbt Core 1.12.3): the `unit_s4` selector picks exactly the S4 nodes; the ERP unit is unchanged.
- **s08f script defect (not a finding):** the insert after `SHOW DBT PROJECTS` used a `latest_version` column that does not exist; fixed. The earlier steps of the first run (`S8f.00` to `S8f.10`) ran.

## 2026-10-07: S8g, in-place deployment

Evidence: `evidence/S8g_20261007.csv`. **Observed: `ALTER DBT PROJECT ... ADD VERSION FROM <git path>` on the live-version object replaces its files in place, and keeps the unit roles' grants, the object, and the canonical state of earlier executions** (an execution from before two `ADD VERSION` statements, one with changed files, is still located). The S4 code was deployed this way (`unit_s4` selector live; ERP still compiles). **SLD 3.2 and 12.7: the deployment step is `ADD VERSION`; `CREATE OR REPLACE` drops the grants and orphans the canonical state and is for first creation only.** Not tested: file removal; a change of dbt version.

## 2026-10-07: S4 complete

Evidence: `evidence/S4_20261007.csv`. Write-up in `spikes/S04_history_snapshots/README.md`.

- **Observed: all 35 cases PASS on the first run.** The incremental CDC history (merge on `(key, source_seq)`, validity recomputed for every key that received a change) is correct for inserts, updates, deletes as tombstones, a redelivered change (stored once) and a late change (slots in by ordering value, re-closes its neighbour, does not become the current state). The snapshot, stamped with the unit watermark through a `snowflake__snapshot_get_time` override that reads `<unit>__build._freeze`, is identical after a discarded and retried build (including when the failed build had already run the snapshot), and its validity equals the published watermark. A tampered history fails `history_contiguous`.
- **Design effect:** SLD 6.7 confirmed; history and snapshots are permanent and rebuilt from the last good state on every run (SLD 10.7 rule 4). LLD: `full_refresh: false` on permanent tables.

## 2026-10-07: S6 built (not yet run)

`spikes/S06_macros_state/`: `s06a` (dev target and the canonical state Q0) and `s06b` (`state:modified` and `--defer` against Q0). `profiles.yml` gains a `ci` target; `stg_erp__accounts.sql` gets a leading comment as the change to detect. Offline (dbt Core 1.12.3): the `prod_erp`, `ci` and `dev` targets compile the ERP unit; views keep bare identifiers; in `ci`, `erp_accounts` reads `SILVER.ci_erp.stg_erp__accounts` (no defer), schemas are `ci_<unit>`.

## 2026-10-07: S6 run 1

Evidence: `evidence/S6a_run1_20261007.csv`, `evidence/S6b_run1_20261007.csv`. Write-up in `spikes/S06_macros_state/README.md`.

- **Observed:** a stage path given to `--state` is not read (`Got a state selector method, but no comparison manifest`, for every form). Snowflake's mechanism is the `IMPORTS = ('<path>' AS 'state')` clause of `EXECUTE DBT PROJECT` with `--state ./imports/state` (documented; syntax to be confirmed by run 2). The canonical state Q0 still locates after an in-place deployment of changed code.
- **Observed:** without `--defer`, a CI build of a table whose parent view is not in the CI schema fails; the published schema is untouched by CI steps.
- **Defect fixed:** the freeze macro now creates the dev and CI schema (non-prod targets only); the first dev and CI freezes had failed on the missing schema.

## 2026-10-07: S6 run 2: state, defer and slim CI work

Evidence: `evidence/S6b_run2_20261007.csv`, `evidence/S6b_listings_20261007.csv`. Write-up in `spikes/S06_macros_state/README.md`.

- **Observed: the canonical state is handed to dbt with `IMPORTS = ('<path>' AS 'state')` and `--state ./imports/state`; the path must be the execution's `target/` directory** (the directory `LOCATE_DBT_ARTIFACTS` returns fails with "no comparison manifest"). The `state_query_id` recorded in the `PUBLISHED` event is enough.
- **Observed: `--defer` reads unselected parents from the published schema; `state:modified.body+ --defer` builds exactly the changed view and its dependent table in `ci_erp`**; the published schema is untouched; without `--defer` the build fails.
- **Observed, against the hypothesis: a target-dependent schema does not make every node "modified"**: plain `state:modified` in the CI target lists only the changed model (probably because dbt compares the unrendered schema configuration).
- **SLD 3.2 confirmed** (canonical state for CI); SLD 10.4 sketch extended: the freeze creates the dev or CI schema in non-prod targets. Remaining for S6: the dev-target rerun (`s06a2_dev_only.sql`).

## 2026-10-07: S6 complete (dev target)

Evidence: `evidence/S6a2_dev_20261007.csv`. **Observed: all PASS.** In the dev target the steward's freeze and build land in `silver.dev_erp`, views keep their bare identifiers, PII is masked for the developer, and the published `erp` schema is untouched. S6 conclusions are in `spikes/S06_macros_state/README.md`.

## 2026-10-07: S10 built (not yet run)

`spikes/S10_consistent_reads/`, `setup/10_core_prereqs.sql`, the Core unit in `dbt/silver` (two reads of the same upstream data 70 s apart plus a `same_rows` test), the `input_clones` mapping in `macros/unit_schemas.sql`, and input clones, freeze skipping and clone cleanup in the publish procedure (`setup/08`). Offline (dbt Core 1.12.3): with `publish_unit: core` the Core models read `SILVER.core__in_erp` and `SILVER.core__in_crm`; with `input_clones` overridden or no unit published they read the published schemas; the ERP unit is unaffected. One defect found offline: a YAML description containing `: ` in `selectors.yml`.

## 2026-10-07: S10 run 1: a selector defect, and what held

Evidence: `evidence/S10_run1_20261007.csv`, `S10_erp_failures_20261007.csv`, `P2_setup10_20261007.csv`. Write-up in `spikes/S10_consistent_reads/README.md`.

- **Found: a unit selector must be closed under the unit, not under dependency.** `source:<frozen> children: true` selects every descendant, including other units' models that read this unit's outputs. Once Core read ERP, every ERP publication failed (`Schema 'CORE' already exists, but current role has no privileges on it`). Units are now selected by folder path only. This removed the main test of run 1 (ERP never published mid-build); run 2 repeats it.
- **Observed:** the Core unit publishes through the procedure with input clones (recorded, dropped afterwards, no freeze, no raw); the unit watermark is the minimum of its upstream watermarks; a consumer role and another unit's role cannot clone an upstream unit schema, the Core role (inheriting the unit roles) can, frozen inputs included; views in a clone keep their bare identifiers; three clones took 2.8 s on average.

## 2026-10-07: S10 complete

Evidence: `evidence/S10_run2_20261007.csv`. Write-up in `spikes/S10_consistent_reads/README.md`.

- **Observed: the problem reproduces.** Core built without input clones while ERP published in the middle read 38 orders in one model and 40 in another (the swap fell between the two reads); the `same_rows` test caught it.
- **Observed: the mitigation works.** With zero-copy clones of the upstream published schemas taken at the gate and dropped after the run, the same scenario publishes consistently (reads agree, data older than the new upstream version, the swap inside the run, the clone before it); a base view in a cloned schema keeps reading the clone's frozen input after the upstream publishes again (S1 holds for a schema clone). Cost: seconds for small schemas.
- **Design effect (SLD 10.9):** adopt the input clones; the privilege model is the open point (the Core role inherited the unit roles; alternatives: a steward-owned clone step, or a dedicated read-only role). Unit selectors must be closed under the unit (SLD 10.3).
