# Spikes: Multi-Project dbt on Snowflake

Empirical validation of the High Level Design documents *Multi-Project dbt on Snowflake: Architecture Overview* v1.3 (the **Overview**) and *Silver Layer Design* v1.3 (the **SLD**), ahead of the Low Level Design.

The spike questions are those listed in SLD Section 14. This repository holds every script that was run, and the evidence each run produced, so that every conclusion in the spike report can be traced to a script and an observed result.

## Ground rules

1. **Observed versus documented.** Every finding is classed as one of:
   - **Observed**: produced by a script in this repository, with the result row committed under `evidence/`.
   - **Documented only**: taken from Snowflake or dbt documentation and not tested here, with the reason (usually trial-account scope).
2. **ACCOUNTADMIN is for setup only.** Each spike step runs under the role the design assigns to it: per-unit service role, steward, platform, or consumer. A privilege test run as ACCOUNTADMIN proves nothing.
3. **Secondary roles are disabled** in every spike script (`USE SECONDARY ROLES NONE`), and each evidence row records the secondary roles in force. New Snowflake users default to `DEFAULT_SECONDARY_ROLES = ('ALL')`, which would silently grant the union of every role the user holds, invalidating privilege results.
4. **Scripts are idempotent.** Each spike drops and recreates its own objects, so it can be rerun from the top at any time.
5. **Synthetic data only.** Nothing in this repository or the trial account comes from the organisation.

## Scope limits agreed with the Engineering Advisory Board

Not validated here, because a single trial account cannot show them:

- Behaviour at production volumes (S5 clone time and S9 retained storage are measured only for trends on synthetic data).
- Anything that needs a second account (S11 replication and failover).

## Layout

```
setup/                  Phase 0, run in order
  00_foundation.sql       warehouse, resource monitor, evidence table, PROBE procedure
  01_account_checks.sql   edition, live version, supported dbt versions, secondary roles
  02_roles.sql            first-cut role catalogue, RAW/SILVER/ANALYTICS_OPS databases
  03_git_integration.sql  API integration and Git repository object (edit placeholders)
  04_hello_dbt.sql        dbt project object from Git, version pinning, live version
  05_governance.sql       governance role, classification tags, masking policies (S9 onwards)
  06_silver_prereqs.sql   Phase 2: second unit role, published schemas, simulated landing, run control
  07_silver_project.sql   Phase 2: deploy the Silver dbt project object
  08_publish_procedure.sql Phase 2: the publish procedure and run-control helpers
  09_s4_prereqs.sql       Phase 2: the S4 unit (CDC history and snapshot sources)
dbt/hello/              Minimal dbt project used to confirm deployment and runtime versions
dbt/silver/             Shared Silver dbt project (Phase 2): macros, selectors, ERP and CRM units
spikes/
  S01_view_binding/     README.md (question, method, result) + script
  S02_swap_grants/
  ...
evidence/               Exported evidence rows, one CSV per spike run
docs/
  spike-log.md          Chronological log of runs, findings and decisions
  hld/                  The two HLDs updated to v1.4 after the spikes; v1.3 originals in hld/v1.3/; CHANGES-v1.4.md
```

## Evidence convention

All observations go into one table, `SPIKE_LAB.EVIDENCE.OBSERVATION`, created in `setup/01_foundation.sql`.

Most observations are made with the caller's-rights procedure `SPIKE_LAB.EVIDENCE.PROBE`. It runs one SQL statement as the **calling role**, captures the first column of the first row (or the error message), compares it with an expected `ILIKE` pattern, and writes a row:

| Column | Meaning |
|---|---|
| `RUN_ID` | One id per script execution (`SET RUN_ID = (SELECT UUID_STRING())` at the top of each script) |
| `SPIKE`, `CASE_ID` | For example `S1`, `S1.04` |
| `DESCRIPTION` | What the case shows |
| `SQL_TEXT` | The exact statement probed |
| `EXPECTED` | `ILIKE` pattern, for example `NEW` or `ERROR:%does not exist%`. `NULL` means informational |
| `OBSERVED` | First value returned, or `ERROR: <message>` |
| `OUTCOME` | `PASS`, `FAIL` or `INFO` |
| `ROLE_NAME`, `SECONDARY_ROLES` | The calling role and secondary roles in force |
| `OBSERVED_AT`, `SF_VERSION` | When, and on which Snowflake release |

`EXPECTED` records what the HLD predicts. A `FAIL` is a finding, not a script error.

After running a spike, export its rows (query at the end of each script) to `evidence/<spike>_<yyyymmdd>.csv` and commit.

## How to run a spike

1. In Snowsight, open the spike's `.sql` file from the Git repository stage (or paste it into a worksheet).
2. Run it top to bottom. The script switches roles itself; your user needs the spike roles granted (done in `setup/02_roles.sql`).
3. Run the final evidence query, download the CSV, and add it under `evidence/`.

## Status

| Spike | Question (SLD 14) | Status |
|---|---|---|
| Phase 0 | Edition, live version, supported dbt versions, roles, Git, hello project | **Complete** (2026-10-05) |
| S1 | View-relative resolution across swap and clone (load-bearing) | **Complete**: views PASS; semantic views need published-name rule (PASS) |
| S2 | Swap and grants | **Complete**: grant, swap, revoke; clone `WITH MANAGED ACCESS` |
| S3 | Failure signalling from `EXECUTE DBT PROJECT` | **Complete**: dbt failures raise; the procedure fails safe and attributes them |
| S4 | Snapshots and CDC history under retry | **Complete**: CDC history correct (late, redelivered, deletes); watermark-stamped snapshots idempotent under retry |
| S5 | Clone cost (trend only) | Deferred (needs production volumes) |
| S6 | Macros and state across targets | **Complete**: dev, CI and prod overrides; canonical state imported with IMPORTS; --defer and slim CI work |
| S7 | Dynamic tables (optional) | Deferred |
| S8 | Concurrent units on one live-version object | **Complete**: concurrent tasks per unit work; `ADD VERSION` keeps grants and state, `CREATE OR REPLACE` does not |
| S9 | Frozen inputs: visibility, retained storage (trend), tag carry-over | Visibility, S9b to S9f and the storage trend (S9c) **complete** |
| S10 | Consistent reads across units | **Complete**: input clones at the gate give one version per upstream unit for the whole build |
| S11 | Object identity (replication out of scope) | Deferred |
| S12 | Unit lease, stale STARTED, DEPLOYED trigger | **Complete**: all PASS; 20-way concurrency confirmed |
| S13 | dbt Fusion (optional) | Deferred |

**HLD update (2026-10-07):** all findings are folded into `docs/hld/` (Overview and Silver Layer Design v1.4). S5, S7, S11 and S13 were agreed with the team as not deal breakers and deferred.
