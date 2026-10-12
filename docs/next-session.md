# Handover: state at end of 2026-10-12

## Where things stand

- **This repository is the working home** of the LLD (since 2026-10-11) and is self-contained. The spikes repository, [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026), is frozen at `e4800aa`; everything the LLD cites from it is in `reference/spikes/` (read-only).
- **Spikes accepted.** HLD v1.4 is the baseline (`docs/hld/`). Deferred: S5, S7, S11, S13.
- **LLD** in `docs/lld/`: component map, decision register, component 1 (Identity and Access, `01-identity-and-access.md`), and the access map (`access-map.md`: roles, ownership and privileges as built, with diagrams). Decided 2026-10-09: IA-1, IA-2, IA-3.
- **Approach:** LLD and prototype together, in increments, one pull request per increment (`docs/lld/README.md`, "Approach").
- **Working practice:** Claude works on branch `claude/dazzling-sagan-ludxca`; the Snowsight Git workspace follows that branch (Pull after each Claude push). Each increment ends with a pull request, merged with **Create a merge commit**, after which the branch carries on.

### Prototype (trial account, `prototype/README.md`)

| Increment | Status | Evidence | Verified |
|---|---|---|---|
| 0 Clean slate (lab foundation, spike teardown, Git integration) | Done 2026-10-11 | `evidence/INC0_20261011.csv` | |
| 1 Unit onboarding (steward self-service) | Done 2026-10-12, merged (PR #2) | `evidence/INC1_20261012.csv` | V-IA-9 |
| 2 First publications under the unit roles | Done 2026-10-12, merged (PR #3) | `evidence/INC2_20261012.csv`, `_publish_log.csv` | V-IA-1, V-IA-7 |
| 3 Consistent reads through input clones (Core) | **Being drafted** on the branch | | V-IA-2, V-IA-3 (planned) |

Key findings so far (details in the prototype README "Results" and LLD 01, Sections 8 and 11):

- An owner's-rights procedure cannot `GRANT OWNERSHIP ... COPY CURRENT GRANTS` without `MANAGE GRANTS`: objects are handed over with **no grants**, and grants follow (INC1.01).
- In a **managed-access schema**, an object can be handed only to a role **below the schema owner** (INC2.10). Hence `SILVER_SCHEDULER`, which holds every unit role and owns `silver.tasks`.
- `OPERATE` lets the operator run a unit's task; the run is the unit role's (V-IA-7).
- dbt `grants` to a reader **database role** work and survive clone and swap (V-IA-1); dbt never revokes database-role grants (from the dbt-snowflake code, untested).
- `USE ROLE` activates any role in the user's hierarchy; a branch name with a slash must be double-quoted in a Git stage path.

### Decisions taken in the session of 2026-10-12

- **I2-1** (prototype): unit tasks live in `silver.tasks`, owned by `SILVER_SCHEDULER`; proposed for RC-1.
- **Increment 3 reuses `SILVER_SCHEDULER` for input clones** instead of a separate `SILVER_CLONER`: the privileges are the same (every unit role).
- **Role names stay as they are until EN-2** (naming conventions) settles all names. Candidate for the scheduler: `SILVER_ORCHESTRATOR`. Renaming is one statement (`ALTER ROLE ... RENAME TO ...` keeps grants and ownership).

## Next steps

1. **Increment 3**: review the draft (`prototype/README.md`, "Increment 3"), then run it in the order listed there; export the demo evidence to `evidence/INC3_<date>.csv`; fix what fails; pull request.
2. Confirm prototype choices I2-2 to I2-7 (`prototype/README.md`) if not done at the Increment 2 review.
3. Increments 4 (clear values and the sensitive source; GV-3) and 5 (CI under its own role; IA-5).
4. LLD component 3 (environments and naming, EN-1, EN-2), which fixes the placeholder names, including the scheduler's.

## Housekeeping

- Deploy the dbt project with `$git_ref = 'main'` in `prototype/07_deployment/i2_30_project_object.sql`, or the branch name while a change is unmerged (it is double-quoted in the path).
- The trial account and the GitHub token expire about 30 days after 2026-10-05 (about **2026-11-04**). Scripts are idempotent, so the prototype can be rebuilt elsewhere from this repository.
- The prototype is independent of the spike objects: its own warehouse `LLD_WH` (resource monitor `LLD_RM`, quota 60 credits), evidence store `LLD_LAB.EVIDENCE`, Git objects `LLD_LAB.GIT` and `LLD_GIT_API`. `SPIKE_LAB`, `SPIKE_WH`, `SPIKE_RM` and `SPIKE_GIT_API` remain as the spike record, unused.
- Evidence files follow `INC<n>_<yyyymmdd>.csv`; a failed first run is kept as `_run1`.
