# Low Level Design: Multi-Project dbt on Snowflake

Working documents for the Low Level Design (LLD) that follows the High Level Design v1.4 (`docs/hld/`): the *Architecture Overview* (the **Overview**) and the *Silver Layer Design* (the **SLD**).

**Status:** in progress. The spikes are accepted; remaining issues are dealt with here as the components are designed.

## Documents

| Document | Purpose |
|---|---|
| [`component-map.md`](component-map.md) | The ten components: for each, what it owns, its interfaces, its reference in the HLD and the spike skeleton, its open items and its dependencies |
| [`decision-register.md`](decision-register.md) | Every open design decision, one row each, with options, the evidence that constrains it, and its status |
| [`01-identity-and-access.md`](01-identity-and-access.md) | Component 1: role catalogue, service roles, consumer access, grant mechanics |

Further component documents are added in this order (component map, "Order of work"): environments and naming (3), governance (2), Silver dbt project (4), publication (5), run control (6), deployment and CI/CD (7), consumer interface (8), operations and cost (9).

Planned deliverables beyond the component documents:

- **Operations runbook:** standard operations (onboarding and retiring a unit, re-running a unit, full refresh, break-glass access, dbt runtime upgrade, restoring a failed unit), written once each operation exists in the prototype.

## Approach: design and prototype together

Agreed 2026-10-09. The LLD and a prototype on the trial account (`prototype/`) proceed together, in **increments**: each is a small piece of working value that can be demonstrated, tested and discussed on its own. Guardrails:

1. **Decision before code.** A script relies only on the HLD baseline and on decisions that are **Decided** in the register, and names the decision id it implements. A design choice that turns up while building goes into the register first; small implementation choices are listed in the component document's "Prototype" section and confirmed in the increment's review.
2. **Spike scripts stay evidence.** `setup/` and `spikes/` are frozen as the record of what was tested. The prototype lives in `prototype/`, organised by component and written as the production scripts would be, never copied from a spike.
3. **Verification items use the spike evidence convention**: the `PROBE` procedure and rows in `evidence/`, so a design claim is traceable to an observation.
4. **Every component document has a "Prototype" section** naming its scripts and verification results. The document says what is intended; the prototype shows it works.
5. **Trial-account shortcuts are listed, not absorbed**: one user holding every role, `ACCOUNTADMIN` for set-up, a personal access token for Git, a single account for every environment. Each is written down where it occurs, so the production build replaces it deliberately.
6. **Rebuildable from scratch.** Every script is idempotent and ordered, so the prototype can be rebuilt on the production account once the trial expires (about 2026-11-04).
7. **Names are defined in one place per script or procedure** (constants at the top of a procedure; the role and object lists in `prototype/README.md`) until EN-2 is decided, so applying the naming conventions is a mechanical change, not a redesign.

### Increments and pull requests

One pull request per increment. It is opened when the increment's scripts are written, and merged once the demo has run on the trial account, its evidence is committed and the review is done. The pull request is the review gate: its description lists the decisions it implements and the implementation choices to confirm.

## Conventions

- **Evidence classes**, as in the spikes: **Observed** (a spike script produced it; the evidence is cited by case id), **Documented** (Snowflake or dbt documentation, not tested here), **Proposed** (a design choice of this LLD, not yet agreed), **Decided** (agreed, with the date and the decision id).
- **Decisions** are recorded once, in `decision-register.md`, and discussed in the component document that owns them. A component document never silently decides something the register lists as open.
- **Verification items** (`V-<component>-<n>`) are small checks that a design choice depends on but no spike covered. They are listed in the component document; the trial account (until about 2026-11-04) can run them.
- References: `SLD 10.4` is section 10.4 of the Silver Layer Design; `Overview 6.2` likewise; `S10.C3` is case C3 of spike S10; `setup/08` is `setup/08_publish_procedure.sql`. Paths under `setup/`, `spikes/`, `dbt/silver/` and spike evidence refer to the frozen spikes repository, [OlavJo/dbt-spikes-2026 at `e4800aa`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa) (see the repository README).
