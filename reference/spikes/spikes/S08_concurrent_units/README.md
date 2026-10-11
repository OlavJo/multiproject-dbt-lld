# S8: concurrent units on one live-version project object

**Status:** script ready, not yet run (`s08_concurrent_units.sql`).

## Question

SLD 3.1 and 10.3: all Silver units share one project object and run concurrently, each with its own `--target-path` and `--log-path`. Does that work, and what do the shared object's "last run" artifacts mean? SLD 14 lists: writeback, partial parsing and `--state` behave independently; which manifest `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET` returns; the effect of a deployment during running units.

## Method

| Part | Cases | What is exercised |
|---|---|---|
| A | S8.A1 to A8 | Two units published **at the same moment** (`ASYNC`) by one orchestrating role. SYSADMIN inherits both unit roles; this also tests whether a task-owner role can run any unit. Each unit publishes; the runs overlap in the log; leases are free; each unit's data and canonical state query id are its own |
| B | S8.B1 | Query history (ACCOUNTADMIN): how many `EXECUTE DBT PROJECT` statements ran at once |
| C | S8.C1 to C3 | `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET` on the object, and `SYSTEM$LOCATE_DBT_ARTIFACTS` per unit (SLD 3.2: with several units on one object the first returns whichever finished last) |
| D | S8.D1 to D6 | Partial parsing per target path: a run of the other unit in between; changed `--vars` (SLD 3.2 expects a full re-parse) |
| E | S8.E0 to E2 | Two concurrent executions sharing one target path (SLD 3.1: writeback is disabled for the execution) |

Part F (a deployment during running units) follows in a separate script, because redeploying the project object can fail running executions.

## Run 1 (2026-10-06): Parts D, E, C, B (`evidence/S8_20261006.csv`, `evidence/S8_DE_detail_20261006.csv`); Part A failed on ownership

**Part A (finding).** Two units called from one session as SYSADMIN both failed at the freeze within 0.7 s: `Schema 'SILVER.ERP__BUILD' does not exist or not authorized. Your primary role SVC_SILVER_ERP must have USAGE ...` (`evidence/S8_A_failures_20261006.csv`). The publish procedure is caller's-rights, so the schema it created (`CREATE SCHEMA ... CLONE`) is **owned by the caller's primary role** (SYSADMIN), while the dbt execution runs as the profile role (`SVC_SILVER_ERP`). **A unit must be run by its own service role**; an orchestrating role that only inherits the unit roles does not work. The LLD must choose between a task per unit, each owned by that unit's role (independent tasks, SLD 12.7), and one shared Silver service role owning every unit schema (which also allows a single task graph, SLD 3.1: one owner). Both failed safely (`FAILED`, leases free, nothing changed). The failure was logged `freeze / source`, which is misleading (a privilege problem is the stewards', not ingestion's); `setup/08` now classes a freeze failure as `source` only when the error names a raw object or Time Travel.

**Part B.** At least **2 `EXECUTE DBT PROJECT` statements were in progress at the same moment** on the one object (E1 and E2 started 0.04 s apart), so the platform runs concurrent executions of one project object.

**Part C.** `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET('silver.ops.silver_layer')` returns one stage path for the whole object (`snow://dbt/SILVER.OPS.SILVER_LAYER/results/query_id_<id>/target/`): whichever execution last succeeded, as SLD 3.2 states. (`LOCATE_DBT_ARTIFACTS` cases errored on the script: the argument must be a constant.)

**Part D: partial parsing is per target path, and variables matter.** D1 to D4 show no "Unable to do partial parsing" message, including D4, ERP after a CRM run on another path. D5, with different `--vars`: "Unable to do partial parsing because config vars, config profile, or config target have changed". D6, back to the original vars: the same message again. So alternating the variables between runs defeats partial parsing in both directions; a variable set per target path (`target/erp`, `target/canonical`) is the rule. Caveat: the evidence is the absence of the warning, the positive line ("Partial parsing enabled") was not captured, and parse times (about 11 s each) did not differ on this small project.

**Part E.** E1 (ERP, new shared path `target/shared`) succeeded with "saved manifest not found. Starting full parse" (expected for a new path). E2 raised `invalid identifier '$2'`: a defect in the helper, not a platform result. `LAST_QUERY_ID()` is session-wide, so in two `ASYNC` children of one session the helper read the other child's statement. **Do not read results with `LAST_QUERY_ID()` where several statements run in one session in parallel**; production tasks have one session each, so the procedure is not affected.

**Part 2** (`s08b_tasks.sql`) repeats A with two tasks, each owned by its unit role.

## Run 2: s08b with one task per unit, first attempt (`evidence/S8b_run1_20261006.csv`)

Both tasks ran under their unit roles (`EXECUTE TASK` and `CREATE TASK` on the unit roles' behalf work), and both publications failed at step 2 within 3 s: `Schema 'ERP__BUILD' already exists, but current role has no privileges on it`. The cause is the leftover `ERP__BUILD` and `CRM__BUILD` schemas of the failed S8 run 1, owned by SYSADMIN, which the unit roles cannot replace. The script now removes them first (a run that fails after creating its build schema leaves it for the next run, which replaces it: **a build schema must never be created by a role other than the unit role**).

**Observed:**

- **A task is not the run's status.** Both task runs are `SUCCEEDED` in task history although the publication they ran failed: the procedure logs `FAILED` and returns a status string, it does not raise. Monitoring and alerting must read run control (`unit_status`, `FAILED` events), not task state (SLD 12.7 already says graph tasks always succeed and record outcomes in the log).
- **`SYSTEM$LOCATE_DBT_ARTIFACTS(<CRM canonical query id>)` called by the ERP role returned `DBT project not found or access denied`** (for the ERP query id it returned the stage path). *Retracted as a role-scoping finding: see run 3, where the CRM role could locate the ERP execution; the cause of the one denial is open and is retested in `s08c`.*
- `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET` returned the last successful execution of the object (unchanged, because no execution succeeded in this attempt).

Script defects (not findings): the steward cannot read the unit-owned schemas (the data checks now run as each unit role), and the query-history filter on time was wrong (B1 empty).

## Run 3: s08b with one task per unit (`evidence/S8b_run2_20261006.csv`): the production shape works

Two tasks, each owned by its unit's service role, started within a second (task history: 16:52:19 and 16:52:20 local):

| Observed | |
|---|---|
| **A1, A2, A3** | **Both units published, and their runs overlapped**: CRM `STARTED` 23:52:24.1, ERP `STARTED` 23:52:25.7, CRM `PUBLISHED` 23:53:09.2, ERP `PUBLISHED` 23:53:14.2. About 45 to 50 s each, the same as a run on its own |
| A5 to A7 | Both leases free; each unit's data is its own (22 current ERP orders, 8 CRM contacts); the two `PUBLISHED` events carry **distinct canonical state query ids**, both compiled ok |
| B1 | 6 `EXECUTE DBT PROJECT` statements (3 per unit: freeze, build, compile); **up to 3 in progress at the same moment** on the one project object |
| C1, C2 | Both task runs `SUCCEEDED` |
| D1 | `SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET` returned the **ERP** canonical compile's path (`query_id_01c78f19-...`), because ERP finished last (23:53:14 against 23:53:09): with two units on one object the object-level pointer is whichever unit finished last, as SLD 3.2 states. The query id recorded per unit in the `PUBLISHED` event is the reliable reference |
| D2, D3, D4 | `LOCATE_DBT_ARTIFACTS` returns a stage path for each unit's canonical query id when called by its own role, and **the CRM role could also locate the ERP execution** (D4). Run 2's single denial (ERP role, CRM query id from an older run) is therefore unexplained: not role scoping as such |
| A4 (defect) | The "no FAILED event" check did not match an empty result; the other cases show there were none |

**Conclusion for SLD 10.3, 3.1:** several units on one live-version project object run concurrently, each in its own task and session, under its own role, without interference in what each publishes. The cost of concurrency is not visible at this scale (a unit takes the same time alone or with another).

## Still open: `s08c_shared_path.sql`, `s08d_deployment.sql`

- **s08c:** two executions on one target path as two tasks (one session each, so the `LAST_QUERY_ID()` problem of run 1 does not arise); a later single execution on that path; and the unexplained `LOCATE_DBT_ARTIFACTS` denial (the ERP role, an older CRM execution).
- **s08d:** a deployment (`CREATE OR REPLACE DBT PROJECT`) about 15 s into a running publication: does the run complete, fail or read the new code; is the object usable afterwards; what happened to grants and written-back state.

## Results: s08c and s08d (`evidence/S8c_20261007.csv`, `evidence/S8d_20261007.csv`)

**s08c, a shared target path.** Two tasks, one per unit role, ran `compile` with the same `--target-path` and `--log-path` 2 s apart: **both `SUCCEEDED`** (about 16 s each), and a later single execution on the path also succeeded (E3). What each logged about writeback and partial parsing was not read (the output probes failed on a boolean concatenation; `s08e` reads them). So concurrent executions on one path do not fail on this runtime.

**LOCATE denial, explained by a hypothesis, not yet proven.** The ERP role located the latest CRM canonical execution (D5), but the **oldest** CRM execution was denied even to the CRM role itself (D6, D7). It is not role scoping. That execution predates the redeploy of the project object (setup/07 re-run at 22:40 for S3), so the hypothesis is that `CREATE OR REPLACE DBT PROJECT` makes a new object and the artifacts of executions of the previous one are no longer reachable. `s08e` tests it directly (an execution from before a redeploy and one from after, before and after a further redeploy).

**s08d, a deployment during a run: inconclusive on overlap.** The publication completed (`STARTED` 00:05:20, `PUBLISHED` 00:06:11) and the redeploy statement finished at 00:06:11.6, so the redeploy ended with the run and may or may not have overlapped it (the fetch and create took longer than the 15 s wait). The object was usable afterwards, with the grants restored by the script (S8d.07: the next batch published; S8d.08: a new last-successful pointer). `s08e` reads the statement times and also checks whether a redeploy drops the unit roles' grants.

## Results: s08e (`evidence/S8e_20261007.csv`, `evidence/S8e_query_history_20261007.csv`)

**Confirmed: `CREATE OR REPLACE DBT PROJECT` makes the artifacts of all earlier executions unreachable.** An execution from before the s08d redeploy: `DBT project not found or access denied` (B1). One from after it: found (B2). After one more redeploy, the same id: denied (B4). SLD 3.2's canonical state is lost at every deployment, until each unit publishes again (the `DEPLOYED` event makes every unit publish, SLD 12.7, which re-establishes it).

**Confirmed: `CREATE OR REPLACE DBT PROJECT` drops every grant.** Afterwards `SHOW GRANTS` lists one row, `SILVER_STEWARD:OWNERSHIP` (D2); a unit role executing the object is refused (`DBT PROJECT ... does not exist or not authorized`, D3); after re-granting it works (D4). The deployment step must re-grant, or use a mechanism that keeps the grants (`s08f`).

**A deployment during a running publication does not break the run** (query history, PDT): the ERP build ran 17:05:39 to 17:05:58; `CREATE OR REPLACE DBT PROJECT` ran 17:05:42 to 17:06:10, **overlapping the build and the run's canonical compile (17:05:58 to 17:06:11)**; the unit still logged `PUBLISHED`. The state id that publication recorded belongs to the replaced object and is unreachable. The deployment runs its own `dbt compile` (about 25 s, as a nested `EXECUTE DBT PROJECT FROM '@git/...'`), a built-in check that the project compiles.

**Shared target path (A1, A2):** both executions logged `success=true` and no writeback lines. The ERP run logged "Unable to do partial parsing", the CRM run did not, although its `--vars` differ. Whether writeback was silently disabled for either cannot be read from the output. The per-unit target paths of the design remain the safe choice.

## Conclusions for the design (SLD 3.1, 3.2, 10.3, 12.7)

1. **Several units run concurrently on one live-version project object**, each as its own task under its own role, with no interference in what each publishes and no measurable cost at this scale (a run takes the same time alone or with another).
2. **A unit must run as its own service role**, because the build schema it creates is owned by the caller's primary role while dbt runs as the profile role. The LLD must choose between a task per unit owned by that unit's role and one shared Silver service role owning all unit schemas (which also allows a single task graph).
3. **A task is not the run's status**: monitoring reads run control.
4. **Per-unit canonical state is the query id in the `PUBLISHED` event**; the object-level "last successful run" pointer is whichever unit finished last. Canonical state is lost at each deployment and returns with the next publication of each unit.
5. **Deploy with `ALTER DBT PROJECT ... ADD VERSION FROM <git path>`, not `CREATE OR REPLACE`** (S8g): the live version's files are replaced in place; the grants, the object and the canonical state of earlier executions all survive (see Results, s08g). `CREATE OR REPLACE` is for the first creation only: it drops the grants and orphans earlier executions. A deployment is followed by a `DEPLOYED` event (SLD 12.7), and is safe while units run.
6. **Partial parsing is per target path**; changed `--vars` force a re-parse, so each target path keeps one variable set (`target/<unit>`, `target/canonical`).
7. **`LAST_QUERY_ID()` is session-wide**: not for concurrent children of one session. Production tasks have one session each.

## s08f (first run, 2026-10-07): ADD VERSION on the live-version object is accepted

`ALTER DBT PROJECT silver.ops.silver_layer ADD VERSION FROM '@<git repo>/branches/main/dbt/silver'` returned **`Successfully deployed new files to the live version.`** (S8f.00 to S8f.10; the script then stopped on a column that `SHOW DBT PROJECTS` does not have, a script defect). So there is an **in-place deployment** for the live version, distinct from `CREATE OR REPLACE` (which creates a new object, drops the grants and orphans earlier executions). Whether it keeps the grants and the canonical state is checked by `s08g_add_version.sql`, which also deploys the S4 code that way. `COPY GRANTS` is not needed if so.

## Result: s08g (`evidence/S8g_20261007.csv`): an in-place deployment keeps the grants and the canonical state

`ALTER DBT PROJECT silver.ops.silver_layer ADD VERSION FROM '@<git repo>/branches/main/dbt/silver'` (S8f.10, S8g.10) returns `Successfully deployed new files to the live version.` and, unlike `CREATE OR REPLACE`:

| Check | Observed |
|---|---|
| Grants after the first `ADD VERSION` (no re-grant) | unchanged: `SVC_SILVER_ERP:USAGE`, `SVC_SILVER_CRM:USAGE`, owner `SILVER_STEWARD` (S8g.01) |
| The object | still `default_version = LIVE`, `dbt_version = 1.12.3` (S8g.02) |
| A canonical execution from before the deployment | still located (S8g.03); **and still located after a second `ADD VERSION` that changed files** (S8g.12) |
| A unit role executes the object | yes, with no re-grant (S8g.04) |
| Second `ADD VERSION` with new files (the S4 models and macros) | accepted (S8g.10); grants unchanged (S8g.11) |
| The new code is live | the `unit_s4` selector lists its nodes (S8g.13); the ERP unit still compiles (S8g.14) |

**Design effect (SLD 3.2, 12.7):** CI's deployment step is `ALTER DBT PROJECT ... ADD VERSION FROM <git path>` on the existing object. It needs no re-grant, and the canonical state stays reachable, so CI can keep using `state:modified` and `--defer` across deployments without waiting for each unit to publish again. `CREATE OR REPLACE` stays the creation-time statement only. Not tested: removing a file in the repository (does `ADD VERSION` delete it from the live version?), and what an `ADD VERSION` that changes the dbt version does.
