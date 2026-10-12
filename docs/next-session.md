# Handover: state at 2026-10-12

## Where things stand

- **Moved to this repository** on 2026-10-11. The spikes repository, [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026), is frozen at `e4800aa` as the reference milestone; the LLD work started on its branch `claude/exciting-ramanujan-dxi1w8` (commits `e05bd58`, `64f008c`, `b41d315`) is carried over here and that branch is abandoned. This repository is self-contained: the spike material the LLD cites is in `reference/spikes/` (read-only), and `prototype/00_lab_foundation.sql` defines the lab scaffolding (warehouse, cost guard, evidence store, `PROBE`, `RECORD`) that previously came from the spike set-up.
- **Spikes accepted.** HLD v1.4 is the baseline (`docs/hld/`). Deferred: S5, S7, S11, S13.
- **LLD started** in `docs/lld/`: component map, decision register, and component 1 (Identity and Access) drafted. Decided 2026-10-09: IA-1 (service role per unit, with steward self-service onboarding), IA-2 (fixed clone procedure for input clones), IA-3 (reader database role per unit; sensitive sources kept out of the aggregate reader).
- **Approach agreed:** LLD and prototype together, in increments, one pull request per increment (`docs/lld/README.md`, "Approach").
- **Prototype** in `prototype/`: Increment 0 (lab foundation, teardown of spike objects, Git integration) **done** 2026-10-11, evidence `evidence/INC0_20261011.csv`. Increment 1 (unit onboarding) **done** 2026-10-12, evidence `evidence/INC1_20261012.csv`; V-IA-9 Observed, with one constraint (schema hand-over without grants; LLD 01, Section 11). Increment 2 (first publications under the unit roles) **done** 2026-10-12, evidence `evidence/INC2_20261012.csv`; V-IA-1 and V-IA-7 Observed; new utility role `SILVER_SCHEDULER` owns the unit tasks' schema (I2-1).

## Next steps

1. Review and merge the Increment 2 pull request; confirm choices I2-2 to I2-7 (`prototype/README.md`). After the merge, deploy from `main` (`$git_ref = 'main'` in `i2_30`).
2. Increment 3: consistent reads through the clone procedure (`SILVER_CLONER`, IA-2; V-IA-2, V-IA-3); Core builds from input clones of ERP and CRM. Consider merging `SILVER_CLONER` with `SILVER_SCHEDULER`, which already holds every unit role.
3. LLD component 3 (environments and naming), which fixes the placeholder names.

## Housekeeping

- The trial account and the GitHub token expire about 30 days after 2026-10-05 (about 2026-11-04). Scripts are idempotent so the prototype can be rebuilt elsewhere.
- The prototype is independent of the spike objects: its own warehouse `LLD_WH` (resource monitor `LLD_RM`, quota 60 credits), evidence store `LLD_LAB.EVIDENCE` and Git objects `LLD_LAB.GIT`, `LLD_GIT_API`. The teardown leaves `SPIKE_LAB` (spike evidence and Git objects), `SPIKE_WH`, `SPIKE_RM` and `SPIKE_GIT_API` in place as the spike record; the prototype does not use them.
