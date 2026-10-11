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
  06_run_control/             Component 6: run-control tables and procedures
  10_external/                Component 10: the simulated platform landing (raw)
  demo/                       One demo per increment: the scenario, with probes
```

Further component folders (`02_governance/`, `05_publication/`, ...) appear with the increments that need them.

## Increments

| # | Increment | Value demonstrated | Verifies | Status |
|---|---|---|---|---|
| 0 | Clean slate | The prototype's own lab (warehouse, evidence store, Git integration), independent of the spike objects; the spike databases and roles removed, the spike record (`SPIKE_LAB`) kept | | Scripts ready |
| 1 | **Unit onboarding** | Stewards onboard and retire Silver units themselves: a role per unit, reader roles, a sensitive source kept out of the aggregate reader, refusals for bad input | V-IA-9; IA-1, IA-3 | Scripts ready |
| 2 | First publication under the new roles | ERP lands, freezes, builds and publishes through the publish procedure, run by its own task; a consumer reads it through the reader database role | V-IA-1, V-IA-7 | Planned |
| 3 | Consistent reads through the clone procedure | Core builds from input clones taken by `SILVER_CLONER`, reading upstream published objects only | V-IA-2, V-IA-3; IA-2 | Planned |
| 4 | Clear values and the sensitive source | Governance tags and masking with a `PII_CLEAR` access role; Core matches on clear values; HR stays restricted | V-IA-6, V-IA-8; GV-3 | Planned |
| 5 | CI under its own role | A CI build with `IMPORTS` of canonical state and `--defer`, under `CI_SILVER` | V-IA-4, V-IA-5 | Planned |

Each increment ends with: its scripts, a demo with probes, the evidence CSV in `evidence/`, a "Prototype" section in the LLD component document, and a pull request.

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

Every script is idempotent, and the demo resets its own units, so any step can be rerun.

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
