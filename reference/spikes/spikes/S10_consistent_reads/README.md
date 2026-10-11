# S10: consistent reads across units

**Status:** **complete** (2026-10-07). Run 1 found a selector defect; run 2 (`evidence/S10_run2_20261007.csv`) is the result.

## Question

SLD 10.9: a swap is atomic, but a downstream unit (the Core module, Tier 1 and 2 projects) runs many queries over several minutes against **other units' published schemas**. If an upstream unit swaps in its new version in the middle, early models read the old version and later models the new one; the watermark understates freshness (the safe direction) but models of one build can disagree. Time Travel at the gate timestamp is not an option (published objects are recreated on each publication, SLD 10.10).

Candidate mitigation (preferred): **at the gate, the downstream unit zero-copy clones each upstream published schema it reads into a private input schema, and builds from the clones.** Needs: (1) correctness; (2) privileges: a clone requires privileges on every object of the schema, including the frozen inputs that are granted to no consumer; (3) cost; (4) views in the clone rebind to the cloned siblings (S1).

## What is built

- Unit `silver.core` (tier T0.5; `dbt/silver/models/core`): `core_orders_a` and `core_orders_b` read the same upstream data (`erp_orders_current`, `erp_accounts`, `crm_contacts`) **70 seconds apart** in one build (a pre-hook pause), and a test `same_rows` asserts the two agree.
- `var input_clones: {core: [erp, crm]}` and `macros/unit_schemas.sql`: while `core` is being published, a reference to `erp` or `crm` resolves to `core__in_erp` or `core__in_crm`; otherwise to the published schema.
- The publish procedure (`setup/08`): after cloning the unit's own build schema, **clones each upstream Silver unit's published schema** (`create or replace schema silver.<unit>__in_<upstream> clone silver.<upstream>`), skips the freeze for a unit without raw upstreams, drops the input clones after the run (success or failure), and records them and the clone time in the `PUBLISHED` event.
- `setup/10`: the Core unit's service role `SVC_SILVER_CORE`, which **inherits** the ERP and CRM unit roles (so it can clone their schemas completely), its schema, and its run-control rows.

## Method (`s10_consistent_reads.sql`, about 12 minutes)

| Part | What |
|---|---|
| A | The problem: ERP publication is started as a task; the Core unit is built directly **without** input clones (`input_clones` overridden to empty): do the two reads disagree, and does the test catch it? |
| B | The mitigation, through the procedure, with ERP publishing in the middle: the two reads agree; Core is older than upstream; the swap fell inside the Core run after the clone; the input clones are recorded and dropped |
| C | Privileges: a consumer role and another unit's role cannot clone the ERP schema; the Core role can, frozen inputs included. Rebinding: after ERP publishes again, a base view in the clone still reads the clone's frozen input |
| D | Cost: statement times of the clones |

Publication windows (the alternative: prevent an upstream swap while a dependent build that read it is in progress) are not tested; they would couple the schedules and add state to run control.

## Run 1 (2026-10-07: `evidence/S10_run1_20261007.csv`, `S10_erp_failures_20261007.csv`, `P2_setup10_20261007.csv`)

**Found: a Source Entity unit's selector must not select descendants across units.** The ERP selector was `path:models/erp` plus `source:erp_frozen` with `children: true`. `children: true` selects **every descendant of the source**; once the Core models read ERP's models, they are descendants too, so the ERP build selected `core_orders_a` and `core_orders_b` and tried to create the `core` schema, which the ERP role does not own: `Schema 'CORE' already exists, but current role has no privileges on it` (three `FAILED:build` events). Every ERP publication failed from the moment Core existed (and the CRM unit would have failed in the same way). Fixed: a unit is selected by the path of its folder only (its models, its frozen-input sources and the tests declared in its YAML), which drops the three Core nodes from ERP's selection (20 to 17 nodes) and leaves the other units unchanged. A design rule for SLD 10.3: unit selectors must be closed under the unit, not under dependency.

**Because ERP did not publish, the swap never fell inside the Core run**: the Part A reads agreed (30 and 30 orders, no mid-build swap) and B3, B4, C5 and C6 do not test what they describe. Run 2 repeats them after the fix.

**Observed (valid in run 1):**

- **The Core unit publishes through the procedure with input clones** (B1: `PUBLISHED`; the event records `core__in_crm,core__in_erp`), builds nothing from raw and runs no freeze (B8: no frozen inputs in `core`), and the input clones are **dropped after the run** (B6).
- **The unit watermark is the minimum of its upstream watermarks** (B7: Core 23:52:17 = CRM's; ERP was at 01:04:36): staleness propagates to the downstream unit, as SLD 11.2 intends.
- **Privileges (C1 to C4):** a consumer role cannot clone an upstream unit schema (no `CREATE SCHEMA` on `SILVER`); the CRM unit role cannot (`Schema 'SILVER.ERP' does not exist or not authorized`); **the Core role, which inherits the unit roles, clones `silver.erp` completely, frozen inputs included** (the clone contains the `RAW__*` tables).
- **A base view in a cloned schema keeps its bare identifier** (C7).
- **Cost (D1):** 3 schema clones, 2.8 s on average and 3.4 s at most, for schemas of a handful of small objects: a floor, not a production figure (S5 is the clone-cost trend).

## Result, run 2 (`evidence/S10_run2_20261007.csv`): the problem reproduced, the mitigation works

| Case | Observed |
|---|---|
| S10.00, S10.01 | The corrected selectors deploy in place (`ADD VERSION`); ERP publishes again |
| **A1, A2, A3 (the problem)** | Core built **without** input clones while ERP publishes in the middle: **`core_orders_a` read 38 orders and `core_orders_b` read 40** (an ERP swap, 01:58:40 UTC, fell between the creation of the two models at 01:58:01 and 01:59:12). The consistency test `same_rows` **caught it**: `Got 2 results, configured to fail if != 0`, the build failed, nothing was published |
| **B1 to B5 (the mitigation)** | The same scenario through the procedure with input clones: **`PUBLISHED`**; the two reads **agree**; Core is **older than upstream** (ERP published after the clone); the ERP swap fell **inside** the Core run and the **clone was taken before it**; the event records `core__in_crm,core__in_erp` |
| B6 to B8 | The input clones are **dropped** after the run; the Core unit's watermark is the minimum of its upstream watermarks (23:52:17, the stale CRM one, while ERP was at 01:59:30); no frozen inputs and no raw access in Core |
| C1, C2 | A consumer role (no `CREATE SCHEMA`) and another unit's role (no `USAGE` on the schema) cannot clone an upstream unit schema |
| **C3, C4** | **The Core role, which inherits the unit roles, clones `silver.erp` completely, frozen inputs included** |
| **C5, C6, C7** | After ERP publishes again, **a base view in the clone still reads the clone's frozen input** (`ISOLATED_FROM_NEW_PUBLICATION`) and keeps its bare identifier: **S1's rebinding holds for a schema clone of a published unit** |
| D1 | 6 schema clones in the window: **4.2 s on average, 11.6 s at most** (the largest is a clone of a whole unit schema including the frozen inputs): small schemas, so a floor; S5 is the clone-cost trend |

## Conclusions for the design (SLD 10.9, 10.7, 10.3, 11.2)

1. **The candidate mitigation of SLD 10.9 works**: a downstream unit that clones the upstream units' published schemas at the gate and builds from the clones reads **one version per upstream unit for its whole build**, however long the build and whatever the upstream units publish meanwhile. Without it, two reads a minute apart saw different versions (38 and 40 orders).
2. **A consistency test in the downstream unit is a cheap detector for the unprotected case** (`same_rows` between two reads of the same upstream data); it is worth keeping on units that read several models of the same upstream unit.
3. **Privileges are the design cost.** A schema clone needs privileges on every object of the schema, including the frozen inputs, which are granted to no consumer. In this spike the Core role **inherits the ERP and CRM unit roles**; a consequence is that the Core role can also alter or swap the upstream units' objects. The LLD should choose between that, a steward-owned clone step (a procedure owned by a role with access to all Silver schemas, creating clones that it then grants to the downstream unit's role), and a dedicated read-only role on all unit schemas.
4. **Per-upstream, not global, consistency.** The clones of ERP and CRM are taken one after the other, so an upstream swap between the two clone statements could still give Core one version of ERP and another of CRM (each internally consistent). Units are independent publication units (SLD 10.3), so this is accepted; the recorded `inputs_cloned_at` and the unit watermark (the minimum of the upstream watermarks) make it visible and conservative.
5. **A unit's data can be older than its upstream's published data at publication**: the unit watermark is read at the gate, the clone slightly later, and the upstream may publish during the build (B3). This is the safe direction (SLD 11.2) and the next run picks the newer upstream up.
6. **Unit selectors must be closed under the unit, not under dependency** (found in run 1): a source selector with `children: true` selects other units' models once they read it; units are selected by folder path.
7. **Cost**: a clone of a schema is metadata only (seconds for small schemas); the clones are dropped at the end of the run, so the storage they keep referenced is held only for the run. Production-size schemas are S5.
8. **Not tested:** publication windows (the alternative); the effect of cloning many large upstream schemas; a Tier 1 or Tier 2 project (same pattern, other roles); cloning only the objects a unit reads.
