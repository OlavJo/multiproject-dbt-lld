# Decision Register

Every open design decision for the LLD, one row each. Each decision is recorded on its own: where one decision narrows another, that is worked through in the component document when the decision is taken, not here.

**Status:** **Open** (not yet discussed), **Proposed** (a recommendation is written in the component document, awaiting agreement), **Decided** (agreed; date and where it is recorded), **Deferred** (parked, with the trigger to revisit).

**Constrained by** lists the evidence that rules options in or out: spike cases, HLD sections, documented platform behaviour.

## 1. Identity and access

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| IA-1 | Service-role granularity for publication units | (a) one service role per unit (as tested); (b) one shared service role per project (all Silver units under one role) | S8: the run role must own the unit's schemas (caller's rights; `SWAP` needs ownership of both); a task is owned by one role; S10 run 1: a selector defect failed safely because the ERP role did not own `core` | **Decided** 2026-10-09: (a), with steward self-service onboarding of unit roles (01, 7.1) |
| IA-2 | Input-clone privilege model (units that read other units) | (a) downstream role inherits upstream unit roles (as tested); (b) owner's-rights clone procedure owned by a dedicated clone role; (c) read-only role granted on every object of every unit schema | S10.C1 to C4: a schema clone needs privileges on every object, frozen inputs included; frozen inputs are granted to no one | **Decided** 2026-10-09: (b), subject to V-IA-2, V-IA-3 (01, 7.2) |
| IA-3 | Granularity of consumer access (reader database roles) | (a) one reader database role per database (as tested); (b) one per unit, optionally bundled into a per-database reader | S2: schema `USAGE` moves with the swap, so every grantee of schema `USAGE` is granted and revoked around each swap | **Decided** 2026-10-09: (b); sensitive sources are expected (01, 7.3) |
| IA-4 | Role hierarchy and administration | Flat custom roles under `SYSADMIN` (as tested); functional (people) roles over access (database) roles; who creates roles and who grants them | Snowflake system-role model; `setup/02` note | Proposed (01, 7.4) |
| IA-5 | CI and deployment identities | (a) CI runs as the unit's service role (as tested, S6); (b) a CI role per project; deployment by the project object's owner or a dedicated deploy role | S6 not tested under another role; S8e: `CREATE OR REPLACE` drops grants (deployment must use `ADD VERSION`) | Proposed (01, 7.5) |
| IA-6 | Developer access | Developer role per team or per person; what it reads (raw masked, published Silver) and where it writes | S6a2.15: PII masked for the developer role; SLD 10.11 | Proposed (01, 7.6) |
| IA-7 | Human access to service roles | (a) stewards hold unit roles; (b) no human holds a service role in production, break-glass only | Ground rule: secondary roles off; S8: a role that only inherits unit roles cannot run a unit | Proposed (01, 7.7) |
| IA-8 | Authentication of service and CI users | Key pair, OAuth or workload identity federation; network policies | Organisational security policy | Open (organisational) |

## 2. Data governance

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| GV-1 | Masking policies per data type for each classification tag | One policy per tag and data type (string, number, date, variant ...) | S9f: a tagged NUMBER (`length(phone)`) was returned in clear when only a string policy existed | Open |
| GV-2 | Who may declassify, and where the reviewed list lives | Governance holds `APPLY` on the tag; or delegated to stewards; list in version control | S9e.40: `APPLY` on the tag is the control | Open |
| GV-3 | Which roles see clear values, and how a policy names them | Role names in each policy (as tested); an access role checked with `IS_ROLE_IN_SESSION` | S9.26: the unit role reads raw clear; Core and some Tier 1 builds need clear values (01, 6.4) | Open |
| GV-4 | Tag taxonomy and who tags raw | Tag names and allowed values; platform tags at landing or governance tags after | SLD 6.3; S9 | Open |
| GV-5 | Row access policies | Needed or not; where applied | SLD 2 | Open |

## 3. Environments and naming

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| EN-1 | Environment separation | Separate accounts; or one account with databases per environment; or shared databases with schemas per environment (as tested) | Overview 6.1: downstream dev and CI read production Silver | Open |
| EN-2 | Naming conventions | Databases, schemas, roles, warehouses, tasks, project objects | SLD 5.2, 10.3 | Open |
| EN-3 | Per-developer and per-pull-request environments | Databases or schemas per developer and per PR; clean-up | SLD 10.11, 16 | Open |
| EN-4 | Time Travel retention on Silver and analytics schemas | Retention per schema type | S9c: a clone takes its schema's retention; SLD 7.4 | Open |
| EN-5 | How Tier 1 and Tier 2 projects import canonical state | Same pattern as Silver (`PUBLISHED` event, `IMPORTS`) | S6; SLD 3.2 | Open |

## 4. Silver dbt project

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| SP-1 | Changed-key pattern for incremental entity models | Collect changed keys from every contributing input, rebuild roots | SLD 6.6 | Open |
| SP-2 | Durable-key management in crosswalks | Issuance, merges, splits, superseded-key mapping | SLD 9.3, G7 | Open |
| SP-3 | Custom uniqueness test for batch-restricted source tests | New keys against the whole table | SLD 8 | Open |
| SP-4 | Generator for base models and classification tags at onboarding | Tooling, inputs, steward review | SLD 6.2, 6.3 | Open |
| SP-5 | dbt Fusion migration criteria | Criteria and path; S13 when adopting | SLD 3.3 | Deferred (until Fusion is proposed) |

## 5. Publication

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| PB-1 | Consistent reads mechanism | Input clones (adopted, S10); publication windows if clone cost is material | S10; S5 not run | Open (confirm after S5) |
| PB-2 | Semantic views and new columns | Lag one publication; or apply after the swap | S1 | Open |
| PB-3 | Object identity per unit | Option A (replace on publication, baseline); Option B (transactional DML) for selected Tier 1 marts | SLD 10.10; S11 not run | Deferred (until a consumer needs stable identity) |
| PB-4 | Where the publish procedure lives, and how it generalises to Tier 1 and Tier 2 | One generic procedure in the ops database; or one per project database | `setup/08` hard-codes the `silver` database; Increment 2 keeps names as constants at the top of `publish_unit` | Open |

## 6. Run control and orchestration

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| RC-1 | Scheduling | Scheduled gated task per unit (SLD baseline); task graph; stream-driven dispatcher. Sub-question: where unit tasks live and who creates them | A task graph needs one owner (SLD 3.1); S8: task status is not publication status; a task runs as its owner, so a unit's task is owned by its unit role; INC1.01: a hand-over cannot copy grants | Open; task placement proposed for the prototype as I2-1 (`prototype/README.md`, Increment 2) |
| RC-2 | Alerting | Snowflake alerts on run-control views; task notifications; external | SLD 12.6 | Open |
| RC-3 | Configuration deployment | Ops repository with seeds or DDL; review | SLD 12.3 | Open |
| RC-4 | Location and ownership of run control | `analytics_ops.control` owned by the steward role (as tested); or a platform-wide owner | SLD 12.1 | Open |

## 7. Deployment and CI/CD

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| CD-1 | CI platform and pipeline stages | Build, test, `IMPORTS` state, deploy, `DEPLOYED`, package release | SLD 3.2 | Open |
| CD-2 | Release mechanics for untested cases | File removal and dbt-version change through `ADD VERSION` (verify) | S8g: not tested | Open |
| CD-3 | Git integration objects and secrets | Token type and owner; one integration per project or shared | `setup/03` | Open |
| CD-4 | dbt runtime upgrade procedure | CI trial with execution-level `DBT_VERSION`, then release | P0.25; SLD 3.3 | Open |

## 8. Consumer interface

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| CI-1 | Source package repository, generation and tagging | Generator, repository, moving major tag | Overview 6.2; SLD 13.1 | Open |
| CI-2 | Consumer manifest registry write path | CI writes via an owner's-rights procedure | SLD 12.9 | Open |
| CI-3 | Generated packages for Tier 1 outputs read by Tier 2 | Optional per Overview 6.2 | Overview 6.2 | Open |

## 9. Operations and cost

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| OC-1 | Warehouse granularity and sizing | Per tier, per project, per unit | SLD 3.1: tasks need user-managed warehouses | Open |
| OC-2 | Resource monitors | Per warehouse; quotas; actions; who may see them | `setup/00`; INC0.14 (a warehouse's monitor is visible only to roles that can see the monitor, by default `ACCOUNTADMIN`) | Open |
| OC-3 | Cost attribution | Object tags, query tags, warehouse per owner | Overview 10 | Open |
| OC-4 | Disaster recovery | Replicate raw and analytics in one group; or rebuild analytics from raw | SLD 7.4, 10.10 | Open |

## 10. External agreements

| ID | Decision | Options | Constrained by | Status |
|---|---|---|---|---|
| EX-1 | Ingestion contract with the platform team | SLD 4.1 terms | SLD 4 | Open |
| EX-2 | Service-level targets per source; steward review turnaround | Agreed with platform team and consumers | SLD 1.2 | Open |
| EX-3 | Production account prerequisites | Live-version bundle enabled; edition; `TIMEZONE`, `DEFAULT_SECONDARY_ROLES` settings | SLD 3.1, 3.2 | Open |
