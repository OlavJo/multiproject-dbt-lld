# Prototype

A working prototype of the Low Level Design (`docs/lld/`), built on the trial account in **increments**. Each increment is a small piece of working value that can be demonstrated, tested and discussed on its own, and is reviewed as one pull request.

The approach and its guardrails are in `docs/lld/README.md` ("Approach"). In short: the code implements decided designs and names the decision ids; spike scripts (`reference/spikes/`) stay untouched as evidence; observations are recorded with the spike evidence convention; trial-account shortcuts are listed below, not absorbed.

## Layout

Scripts are organised by LLD component, and numbered `i<increment>_<step>` so the run order is clear:

```
prototype/
  00_lab_foundation.sql       Increment 0: lab scaffolding (LLD_WH, LLD_RM, LLD_LAB evidence store, PROBE, RECORD)
  00_teardown_spikes.sql      Increment 0: remove the spike objects (trial account only)
  00_git_integration.sql      Increment 0: Git integration for this repository (LLD_LAB, LLD_GIT_API)
  01_identity/                Component 1: roles, provisioning
  05_publication/             Component 5: the publish procedure
  06_run_control/             Component 6: run-control tables, status, lease, unit tasks
  07_deployment/              Component 7: the dbt project object
  10_external/                Component 10: the simulated platform landing (raw)
  demo/                       One demo per increment: the scenario, with probes
dbt/silver/                   Component 4: the Silver dbt project (deployed from Git by 07_deployment)
```

Further component folders (`02_governance/`, ...) appear with the increments that need them.

## Increments

| # | Increment | Value demonstrated | Verifies | Status |
|---|---|---|---|---|
| 0 | Clean slate | The prototype's own lab (warehouse, evidence store, Git integration), independent of the spike objects; the spike databases and roles removed, the spike record (`SPIKE_LAB`) kept | | **Done** 2026-10-11 |
| 1 | **Unit onboarding** | Stewards onboard and retire Silver units themselves: a role per unit, reader roles, a sensitive source kept out of the aggregate reader, refusals for bad input | V-IA-9; IA-1, IA-3 | **Done** 2026-10-12 |
| 2 | First publication under the new roles | ERP lands, freezes, builds and publishes through the publish procedure, run by its own task; a consumer reads it through the reader database role | V-IA-1, V-IA-7 | Scripts ready |
| 3 | Consistent reads through the clone procedure | Core builds from input clones taken by `SILVER_CLONER`, reading upstream published objects only | V-IA-2, V-IA-3; IA-2 | Planned |
| 4 | Clear values and the sensitive source | Governance tags and masking with a `PII_CLEAR` access role; Core matches on clear values; HR stays restricted | V-IA-6, V-IA-8; GV-3 | Planned |
| 5 | CI under its own role | A CI build with `IMPORTS` of canonical state and `--defer`, under `CI_SILVER` | V-IA-4, V-IA-5 | Planned |

Each increment ends with: its scripts, a demo with probes, the evidence CSV in `evidence/`, a "Prototype" section in the LLD component document, and a pull request.

## Results

**Increment 0** (2026-10-11, `evidence/INC0_20261011.csv`): all cases PASS after one script fix. `00_lab_foundation.sql` ran three times (idempotence shown), the teardown once, the Git integration once.

| Case | Finding |
|---|---|
| INC0.14 | First run FAIL, observed `null`: `SHOW WAREHOUSES` shows the `resource_monitor` column only to roles that can see the monitor (by default `ACCOUNTADMIN`), so `SYSADMIN` reads `null` although the monitor is set. Check moved to `ACCOUNTADMIN`; PASS on the next two runs. Relevant to OC-2: whoever monitors cost needs `MONITOR` on the resource monitors, not just warehouse ownership. |
| INC0.05 | 720 spike observations kept in `SPIKE_LAB` |
| INC0.20 | This repository readable from Snowflake through `LLD_GIT_API` and the PAT secret |

**Increment 1** (2026-10-12, `evidence/INC1_20261012.csv`): 43 PASS, 1 INFO; V-IA-9 Observed. Full results in LLD 01, Section 11.

| Case | Finding |
|---|---|
| i1_10 | First run stopped at the first scripting block: no warehouse selected. Scripts now select `LLD_WH` after their first `USE ROLE` |
| INC1.01 to 03 | First demo run (`evidence/INC1_20261012_run1.csv`): `GRANT OWNERSHIP ... COPY CURRENT GRANTS` in an owner's-rights procedure needs `MANAGE GRANTS`. `onboard_unit` now hands the schema over with no grants; the reader role's `USAGE` comes with publication (F3). PASS on the second run |
| INC1.42 | The unit role, as schema owner, grants `USAGE` to its reader role (the step publication will take) |
| INC1.27 | INFO, as designed: a unit role can create any schema in `silver` (LLD 01, Section 9) |
| INC1.90 | `TASK_RUNNER` holds exactly `EXECUTE TASK` on the account |
| Part 6 | `USE ROLE` activates any role in the user's hierarchy: with its direct grant revoked, `SVC_SILVER_CRM` was activated through `SYSADMIN` (manual check, 2026-10-12). The demo's direct grants of unit roles to the user were removed |

## Running an increment

As with the spikes, scripts run in Snowsight worksheets (or any client that supports Snowflake Scripting blocks), top to bottom, by a user who can assume the roles named at the top of each script.

**Increment 0 and 1, in order:**

| Step | Script | Runs as |
|---|---|---|
| 0.a | `00_lab_foundation.sql` | `SYSADMIN`, `ACCOUNTADMIN` (switches itself) |
| 0.b | `00_teardown_spikes.sql` (edit `v_confirm` to `YES`); trial account only, skip on a new account | `ACCOUNTADMIN` |
| 0.c | `00_git_integration.sql` (paste a token first; see the header) | `SYSADMIN`, `ACCOUNTADMIN` (switches itself) |
| 1.10 | `01_identity/i1_10_foundation.sql` | `USERADMIN`, `SECURITYADMIN`, `ACCOUNTADMIN`, `SYSADMIN`, `SILVER_PROVISIONER` (switches itself) |
| 1.20 | `10_external/i1_20_platform_raw.sql` | `PLATFORM_INGEST` |
| 1.30 | `06_run_control/i1_30_control_tables.sql` | `SILVER_STEWARD` |
| 1.40 | `01_identity/i1_40_provisioning.sql` | `SILVER_STEWARD`, then `SILVER_PROVISIONER` |
| demo | `demo/i1_demo_onboarding.sql` | switches itself; export the final query to `evidence/INC1_<yyyymmdd>.csv` |

**Increment 2, in order** (after the Increment 1 demo, whose units it uses):

| Step | Script | Runs as |
|---|---|---|
| 2.10 | `10_external/i2_10_landing.sql` | `PLATFORM_INGEST` |
| 2.20 | `06_run_control/i2_20_status_and_lease.sql` | `SILVER_STEWARD` |
| 2.30 | `07_deployment/i2_30_project_object.sql` (set `$git_ref`; `main` once merged) | `SYSADMIN`, then `SILVER_STEWARD` |
| 2.40 | `05_publication/i2_40_publish_procedure.sql` | `SILVER_STEWARD` |
| 2.50 | `06_run_control/i2_50_unit_tasks.sql` (first rerun `i1_10` and `i1_40`: the scheduler role and its unit-role grants) | `SILVER_STEWARD`, then `SILVER_SCHEDULER` |
| demo | `demo/i2_demo_publication.sql` | switches itself; waits for each task run (up to 10 minutes); export to `evidence/INC2_<yyyymmdd>.csv` |

Every script is idempotent, and the demos reset or reuse their own units, so any step can be rerun.

## Increment 2: design and choices to confirm

**What it builds.** The first publications under the new roles. The platform lands batches (`raw.control.land_batch`, the landing-complete record last). Run control gains status, the gate and the lease (`i2_20`). The steward deploys one live-version project object from this repository's `dbt/silver` (`i2_30`), with `USAGE` granted once to `SILVER_UNIT_BASE`. `silver.ops.publish_unit` (`i2_40`) runs the validated publication sequence. Each unit gets a task, owned by the unit role, which the operator starts (`i2_50`).

**Relies on.** IA-1, IA-3 (Decided); the HLD baseline for the publication sequence (SLD 10.4), run control (SLD 12) and one project object (SLD 3.1). Open decisions are not taken: PB-4 (the procedure stays in `silver.ops` for Silver), RC-1 (tasks are created but left suspended), CD-1 and IA-5 (the steward deploys interactively).

**Choices to confirm at the Increment 2 review:**

| # | Choice | Why |
|---|---|---|
| I2-1 | **Unit tasks** live in `silver.tasks`, a managed-access schema owned by a new utility role, **`SILVER_SCHEDULER`**, which holds every unit role (`onboard_unit` grants each one to it) and is never held by a person. `provision_unit_task(unit)` (scheduler, owner's rights, called by the operator after `onboard_unit`) creates `silver.tasks.publish_<unit>`, hands it to the unit role with no grants, then grants `OPERATE` and `MONITOR` to `SILVER_OPERATOR`. **Decided for the prototype 2026-10-12**; proposed for RC-1 | A task runs as its owner, so the unit role must own it. Once handed over, only the owner of a managed-access schema can still grant on it (a hand-over cannot copy grants: INC1.01). In a managed-access schema an object can be handed only to a role below the schema owner (first run, INC2.10), and unit roles must not be below the steward (F7). A unit schema cannot hold its task (it is swapped). Same pattern as `SILVER_CLONER` (IA-2 b) |
| I2-2 | The publish procedure grants schema `USAGE` to the unit's own reader role, `silver.reader_<unit>`, around the swap | IA-3; LLD 01, 6.2. The spike granted to `silver.reader` |
| I2-3 | A unit with Silver upstreams is refused (`FAILED:input_clones`) until Increment 3 | IA-2 (b) needs `SILVER_CLONER`; the spike's inherited-role clones contradict IA-2 |
| I2-4 | dbt `grants` on each unit folder, to the unit's reader database role, base views included | LLD 01, 6.2 (one setting per folder). Base views expose cleaned columns of the frozen inputs, not the inputs themselves |
| I2-5 | Each deployment runs `CREATE ... IF NOT EXISTS` then `ADD VERSION`; the first run therefore has two identical versions | Keeps the script free of branching; `ADD VERSION` keeps grants (F8) |
| I2-6 | Onboarding a publishable unit is two operator calls: `onboard_unit`, then `provision_unit_task` | Keeps Increment 1 unchanged; one call once both are proven |
| I2-7 | New event type `TASK_PROVISIONED` in `publish_log` | As choice 5 of LLD 01, Section 11 |

**Expected finding for V-IA-1.** dbt-snowflake (as read in 1.10.8, to be confirmed on the 1.12.3 runtime) leaves grants held by database roles out of its comparison of existing grants. So it grants on every run, which is harmless, and **never revokes** a grant to a database role: removing a reader from `grants` would leave the old grant in place until the table is replaced. The demo checks the first half (INC2.25, INC2.30).

## Trial-account shortcuts

Recorded so the production build replaces each one deliberately (guardrail 5).

| # | Shortcut | Where | Production replacement |
|---|---|---|---|
| T1 | One user holds every role, including the provisioner and, in demos, unit service roles | `i1_10`, demos | No person holds service, provisioner or owner roles (IA-4, IA-7); scripts run by the deployment pipeline |
| T2 | Administrator roles run interactively by that user | `00`, `i1_10` | Version-controlled scripts run by a pipeline or by named administrators (IA-4, CD-1) |
| T3 | One warehouse, `LLD_WH`, for every role | `i1_10` | Warehouses per OC-1 |
| T4 | Git access through a personal access token | `00_git_integration.sql` | CD-3 |
| T5 | One account holds what will be several environments | everywhere | EN-1 |
| T6 | Evidence store and probe procedures in `LLD_LAB` | `00_lab_foundation.sql`, everywhere | Not needed in production; CI tests take their place |
| T7 | Raw landing simulated by the prototype | `10_external/` | The platform team's landing (EX-1) |
