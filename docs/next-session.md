# Handover: state at 2026-10-11

## Where things stand

- **Moved to this repository** on 2026-10-11. The spikes repository, [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026), is frozen at `e4800aa` as the reference milestone; the LLD work started on its branch `claude/exciting-ramanujan-dxi1w8` (commits `e05bd58`, `64f008c`, `b41d315`) is carried over here and that branch is abandoned. This repository is self-contained: the spike material the LLD cites is in `reference/spikes/` (read-only), and `prototype/00_lab_foundation.sql` defines the lab scaffolding (warehouse, cost guard, evidence store, `PROBE`, `RECORD`) that previously came from the spike set-up.
- **Spikes accepted.** HLD v1.4 is the baseline (`docs/hld/`). Deferred: S5, S7, S11, S13.
- **LLD started** in `docs/lld/`: component map, decision register, and component 1 (Identity and Access) drafted. Decided 2026-10-09: IA-1 (service role per unit, with steward self-service onboarding), IA-2 (fixed clone procedure for input clones), IA-3 (reader database role per unit; sensitive sources kept out of the aggregate reader).
- **Approach agreed:** LLD and prototype together, in increments, one pull request per increment (`docs/lld/README.md`, "Approach").
- **Prototype** in `prototype/`: Increment 0 (teardown of spike objects, lab foundation) and Increment 1 (unit onboarding) written, **not yet run**.

## Next steps

1. Run `prototype/00_teardown_spikes.sql`, then `prototype/00_lab_foundation.sql`, then Increment 1 in the order of `prototype/README.md`; export the demo evidence to `evidence/INC1_<date>.csv`; fix what fails.
2. Open the increment 1 pull request (LLD documents, teardown, increment 1, evidence) and review the implementation choices listed in LLD 01, Section 11.
3. Increment 2: first publication under the new roles (project object from Git with `ADD VERSION`, publish procedure, lease procedures, a task owned by the unit role, consumer reads through the reader database role). The Snowflake Git objects kept by Increment 0 (`SPIKE_LAB.GIT`, API integration `SPIKE_GIT_API`) point at the spikes repository; the prototype's dbt project will live here, so Increment 2 adds a Git integration script here that points them at this repository (the integration's `API_ALLOWED_PREFIXES`, the repository object's `ORIGIN`), and the token needs access to this repository (trial shortcut T4).
4. LLD component 3 (environments and naming), which fixes the placeholder names.

## Housekeeping

- The trial account and the GitHub token expire about 30 days after 2026-10-05 (about 2026-11-04). Scripts are idempotent so the prototype can be rebuilt elsewhere.
- Resource monitor `SPIKE_RM` (quota 60 credits), kept by the teardown.
