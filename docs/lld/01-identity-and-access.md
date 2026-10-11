# LLD 1: Identity and Access

| | |
|---|---|
| **Status** | Draft for review |
| **Component** | 1 (component map) |
| **Decisions** | IA-1 to IA-8 (decision register) |
| **HLD** | SLD 3.1, 10.4, 10.7, 10.9, 10.12, 16; Overview 4.3, 10 |
| **Evidence** | S2, S6, S8, S9, S10, S12; `setup/02`, `05`, `06`, `08`, `10` |

Role and object names here are the spike names, used as **placeholders** until naming conventions are fixed (component 3, EN-2). Where a name is new in this document it is marked *(new)*.

---

## 1. Scope

In scope:

- Every principal (human and service users) and every account role and database role.
- Object ownership: who owns each database, schema and shared object.
- Grants: what each role may do, and the mechanics publication depends on (managed access, the grant–swap–revoke sequence, dbt `grants` config).
- The privileges input clones need (SLD 10.9).

Interfaces with other components, but decided there:

- **Which roles see clear PII** is a governance decision (GV-3). This document provides an access role for it (Section 6.4).
- **Database and environment layout** (EN-1, EN-3): this document defines which roles exist in each environment, not how many databases there are.
- **Task layout** (RC-1): this document states who can own a task.
- **Authentication** of users (IA-8) follows organisational policy and is only noted here.

## 2. Principles

1. **The role that runs a unit owns the unit.** The run role, the dbt profile role of the unit's target and the owner of the unit's published and build schemas are the same role (Section 3, F1).
2. **Least privilege per unit.** A unit's role can read its declared upstreams and write only its own schemas. A defect in one unit's code fails that unit, never another unit's published data.
3. **Consumers are granted through database roles, object by object.** Never on build schemas, never with future grants, never to internal objects (SLD 10.7 rule 5).
4. **Shared state is written only through owner's-rights procedures.** Unit roles have no `INSERT` or `UPDATE` on run control (S12).
5. **Account-level privileges stay with administrators and governance.** No unit, CI or developer role holds `MANAGE GRANTS`, `APPLY TAG` or `APPLY MASKING POLICY` on the account.
6. **Secondary roles are off for every service and CI user** (`DEFAULT_SECONDARY_ROLES = ()`), so a session's privileges are its primary role's and nothing else.
7. **Humans do not use service roles in production.** Operational actions go through procedures and tasks (IA-7).
8. **The role catalogue is code.** Roles, grants and ownership are created by version-controlled scripts, reviewed like any other change (CD-1).

## 3. Established by the spikes

These are constraints, not options.

| # | Fact | Evidence |
|---|---|---|
| F1 | A caller's-rights publish procedure creates the build schema as the caller's **primary** role, while dbt runs as the **profile** role. `SWAP WITH` needs ownership of both schemas. A role that only inherits the unit roles cannot run a unit; the unit must run as its own role | S8 Part A; SLD 3.1 |
| F2 | A task runs as its owner, and a task graph needs one owner. A task per unit, owned by the unit role, works | S8b run 3; SLD 3.1, 12.7 |
| F3 | Schema-level `USAGE` **moves with the schema** under `SWAP WITH`. Publication grants `USAGE` on the build schema just before the swap and revokes it just after, for **every grantee** of the published schema's `USAGE` | S2.08 to S2.21 |
| F4 | A schema clone does not inherit managed access; `ENABLE MANAGED ACCESS` needs account-level `MANAGE GRANTS`, even for the owner. `CREATE OR REPLACE SCHEMA ... CLONE ... WITH MANAGED ACCESS` keeps it, with no extra privilege | S2.29 to S2.54 |
| F5 | Grants on child objects are copied by a schema clone and travel with the swap | S2.04; SLD 10.7 |
| F6 | A schema clone needs privileges on **every object** in the schema, frozen inputs included. A consumer role and another unit's role cannot clone a unit schema; a role inheriting the unit roles can | S10.C1 to C4 |
| F7 | The database owner has no access to schemas owned by other roles (the steward could not read unit-owned schemas) | S8b run 1 |
| F8 | `USAGE` on the dbt project object is enough to execute it. `CREATE OR REPLACE DBT PROJECT` drops every grant; `ADD VERSION` keeps them | S8e.D2 to D4; S8g.01 |
| F9 | Owner's-rights lease and log procedures, owned by the steward, keep unit roles away from the tables; unit roles cannot update the lease or insert into the log directly | S12.20 to S12.22 |
| F10 | Creating a propagating tag needs account-level `APPLY TAG`; declassifying needs `APPLY` on the tag | P0 (spike log); S9e.40 |
| F11 | Masking policies tested reveal by `CURRENT_ROLE()`. The unit role reads raw in clear, and its CTAS stores clear values protected only by the propagated tag; the developer role sees masked values | S9.26, S9f.B6, S6a2.15 |
| F12 | A unit role reads only its own source's raw schema | P2.05 |
| F13 | A database role receives `USAGE` on its own database automatically | spike log, `setup/02` |
| F14 | A build schema must never be created by a role other than the unit role: a leftover schema owned by another role blocks the unit | S8b run 1 |

Not tested, and relied on below: see Section 8 (verification items).

## 4. Principals

| Principal | Kind | Uses roles | Notes |
|---|---|---|---|
| Unit tasks | Snowflake tasks (no user) | The unit's service role, as task owner | One task per unit (F2; RC-1) |
| CI user, per repository | Service user | CI role; deploy role | Key pair or workload identity (IA-8); `DEFAULT_SECONDARY_ROLES = ()` |
| Silver stewards | Human | Steward functional role; developer role | Not the owner or service roles in production (IA-7) |
| Contributors (any analytics team, to Silver) | Human | Silver developer role | Pull requests reviewed by stewards (SLD 5.3) |
| Tier 1 and Tier 2 teams | Human | Their project's developer and consumer roles | |
| Consumers (analysts, BI service users) | Human or service | Consumer functional roles holding reader database roles | |
| Governance team | Human | Governance role | |
| Platform team | Human and service | Platform role | Owns raw; no access to analytics objects (SLD 4.1) |
| Administrators | Human | System roles | Setup and break-glass only |

## 5. Role catalogue (draft)

Organised in layers. Each account role is granted to `SYSADMIN` so administrators can manage what it owns (Snowflake's recommended practice). Masking uses the session's own role (F11), so inheritance by `SYSADMIN` does not reveal clear values.

### 5.1 System roles

`ACCOUNTADMIN`, `SECURITYADMIN`, `USERADMIN`, `SYSADMIN`: setup, account-level grants and break-glass only. `USERADMIN` creates roles and users; `SECURITYADMIN` grants roles and account privileges; `SYSADMIN` creates databases and warehouses and transfers their ownership.

### 5.2 Owner roles

Own databases and shared objects. Used by the deployment pipeline and, exceptionally, by named administrators; not by people day to day (IA-4).

| Role | Owns | Notes |
|---|---|---|
| `PLATFORM_INGEST` | `raw` database; landing-complete table | Platform team. Grants `SELECT` on each source's raw schema to that source's unit role, and on the landing-complete table to the steward |
| `SILVER_STEWARD` | `silver` database (not its unit schemas, F7); `silver.ops` (project object, publish procedure); `analytics_ops` (run control tables, views, owner's-rights procedures); Git repository objects | Grants `USAGE` on the project object and procedures to unit roles |
| `GOVERNANCE_ADMIN` | `governance` database: tags, masking policies | Holds account `APPLY TAG` and `APPLY MASKING POLICY` (F10) |
| `<PROJECT>_OWNER` *(new)* | A Tier 1 or Tier 2 project's database, `ops` schema and project object | One per project; the Tier 1/2 counterpart of `SILVER_STEWARD` |

### 5.3 Service roles (one per publication unit)

`SVC_SILVER_<UNIT>` for Silver units (`SVC_SILVER_ERP`, `SVC_SILVER_CORE`); `SVC_<PROJECT>_<UNIT>` for Tier 1 and Tier 2 units. Recommended in IA-1.

| Privilege | On | Why |
|---|---|---|
| `OWNERSHIP` | The unit's published schema and build schema | F1; created by the role itself, `WITH MANAGED ACCESS` (F4, F14) |
| `CREATE SCHEMA` | The unit's database | To recreate the build schema every run. Not scoped by name (residual risk, Section 9) |
| `USAGE` | The project object; the publish procedure; `log_event` and the lease procedures | F8, F9 |
| `SELECT` | Run-control configuration and status views | The gate |
| `USAGE`, `SELECT` | Its own source's raw schema and tables (Source Entity units only) | F12; the freeze |
| Reader database roles of its upstream units | | To read input clones (IA-2) |
| `USAGE` | Its warehouse | OC-1 |
| `EXECUTE TASK` (account) | | To own a task that runs (F2) |
| `CREATE TASK` | The schema holding its task | RC-1 decides where tasks live |
| Clear-PII access role, if granted by governance | | Section 6.4, GV-3 |

Because the unit role owns its managed-access schemas, it applies the dbt `grants` config on published models itself, with no account privilege.

### 5.4 Utility roles

| Role | Purpose | Recommended in |
|---|---|---|
| `SILVER_CLONER` *(new)* | Owns the owner's-rights procedure that takes input clones of upstream unit schemas, grants them to the downstream unit role and drops them. Never granted to a person or to a dbt target | IA-2 |
| `SILVER_PROVISIONER` *(new)* | Owns `onboard_unit` and `offboard_unit`, which create and retire a unit's roles and grants. Holds `CREATE ROLE`; never granted to a person | IA-1, 7.1.1 |
| `TASK_RUNNER` *(new)* | Access role holding the account privilege `EXECUTE TASK`, granted to every service role that owns a task. Owned by `SILVER_PROVISIONER` | 7.1.1 |
| `SILVER_UNIT_BASE` *(new)* | Access role holding the privileges common to every Silver unit role (Section 5.3, except the unit's own schemas, raw and upstream readers). Object owners grant to it once; the provisioner, which owns it, grants it to each new unit role | 7.1.1 |

### 5.5 CI and deployment roles

| Role | Purpose | Recommended in |
|---|---|---|
| `CI_SILVER` *(new)*, `CI_<PROJECT>` *(new)* | Runs CI builds: creates and drops CI schemas, freezes raw into them (Silver), reads published upstream objects through reader roles, executes the CI project object, imports canonical state | IA-5 |
| Deploy | `ALTER DBT PROJECT ... ADD VERSION`, the `DEPLOYED` event, the consumer registry write. Run under the project's owner role (`SILVER_STEWARD`, `<PROJECT>_OWNER`) by the CI user, unless V-IA-5 shows a narrower privilege suffices | IA-5 |

### 5.6 Access roles

Access roles hold privileges on objects and are granted to functional and service roles; they are never used as a session's primary role.

| Role | Kind | Holds | Recommended in |
|---|---|---|---|
| `silver.reader_<unit>` *(new)* | Database role | `SELECT` on the unit's published objects (dbt `grants`); `USAGE` on the unit's published schema, moved by the grant–swap–revoke sequence | IA-3 |
| `silver.reader` | Database role | All `silver.reader_<unit>` roles | IA-3 |
| `<project_db>.reader_<unit>`, `<project_db>.reader` *(new)* | Database roles | The same, for Tier 1 and Tier 2 published objects | IA-3 |
| `PII_CLEAR_<scope>` *(new)* | Account role | Nothing itself; masking policies reveal clear values to sessions that hold it | Section 6.4; GV-3 decides who holds it |

### 5.7 Functional roles (people)

| Role | Holds | Can |
|---|---|---|
| `SILVER_DEVELOPER` *(new)* | Raw read (masked); `silver.reader`; ownership of its development schemas | Build Silver in development (IA-6). Held by stewards and Silver contributors |
| `SILVER_OPERATOR` *(new)* | `SELECT` on run control; `OPERATE` on unit tasks; `USAGE` on the full-refresh procedure | Monitor, re-run a unit through its task, record a full refresh, without holding the unit role (IA-7) |
| `<PROJECT>_DEVELOPER` *(new)* | Upstream reader roles; ownership of its development schemas | Build a Tier 1 or Tier 2 project in development |
| Consumer roles (`ANALYST_TIER1` in the spikes) | Reader database roles | Read published objects |
| `GOVERNANCE_ADMIN` (human use) | | Manage tags, policies, declassification |

## 6. Privileges and grant mechanics

### 6.1 Object ownership

| Object | Owner | Created by |
|---|---|---|
| `raw` database and schemas | `PLATFORM_INGEST` | Platform |
| `silver` database; `silver.ops` | `SILVER_STEWARD` | Setup |
| `silver.<unit>`, `silver.<unit>__build` | `SVC_SILVER_<UNIT>` | The unit role (published schema at unit set-up; build schema every run) |
| Input clones `silver.<unit>__in_<upstream>` | `SILVER_CLONER` (IA-2 recommendation) | The clone procedure, every run |
| Frozen inputs, models (in the unit's schemas) | `SVC_SILVER_<UNIT>` | dbt, every run |
| dbt project object | `SILVER_STEWARD` | Setup (`CREATE`), then deploy (`ADD VERSION`) |
| `analytics_ops` and everything in it | `SILVER_STEWARD` | Setup and the ops repository |
| Tags, masking policies | `GOVERNANCE_ADMIN` | Governance |
| Tasks | The unit's service role | Setup (RC-1) |

### 6.2 Consumer grants and the swap

- **Object grants:** dbt `grants` config on published models only, to the unit's reader database role. Set once per unit folder in `dbt_project.yml` (`+grants: {select: [...]}`), so a new published model in the folder is granted without per-model configuration. Internal models of Tier 1 and Tier 2 projects override it with no grants. *The spikes granted `SELECT` to an account role (`ANALYST_TIER1`); granting to a database role through dbt `grants` is verification item V-IA-1.*
- **Schema `USAGE`:** granted to the unit's reader database role only. The publish procedure grants it on the build schema before the swap and revokes it after (F3), so the sequence is one grant and one revoke per unit, whatever the number of consumers. The procedure reads the reader role's name from configuration instead of hard-coding `silver.reader` (`setup/08`).
- **Consumers** receive reader database roles through their functional roles; a consumer never receives `USAGE` on a schema directly, because the swap would not carry such a grant correctly.

### 6.3 Managed access

Every published and build schema is managed access: created `WITH MANAGED ACCESS` at unit set-up and cloned `... WITH MANAGED ACCESS` every run (F4). Only the schema owner (the unit role) grants on its objects; object owners elsewhere cannot widen access. Input clones need not be managed access: they are private to one run, owned by `SILVER_CLONER`, and never granted to consumers.

### 6.4 Clear values (interface with governance)

The tested masking policies reveal clear values to role names listed in each policy (F11). Two consequences need a decision in governance (GV-3):

1. **Every role that builds from PII must read it in clear, or it stores the masked string.** A CTAS by a role the policy masks writes `***MASKED***` into the table. This matters for the Core unit (identity resolution on email or name would match masked strings) and for any Tier 1 unit that transforms PII. In S10 the Core role inherited the ERP and CRM roles, but a `CURRENT_ROLE()` policy does not see inherited roles, so Core read masked values; S10 did not use PII columns, so this was not observed.
2. **Development and CI read masked values.** Tests that compare values (uniqueness, relationships, accepted values) behave differently on masked data. V-IA-6 checks this for CI.

Proposal for governance to decide: policies reveal to sessions holding a `PII_CLEAR_<scope>` access role, checked with `IS_ROLE_IN_SESSION` (which follows the role hierarchy, unlike `CURRENT_ROLE()`), instead of listing service roles by name. Governance decides which service roles hold it; the list stays short and no policy changes when a unit is added.

### 6.5 Account-level privileges

| Privilege | Held by |
|---|---|
| `MANAGE GRANTS` | `SECURITYADMIN` only |
| `APPLY TAG`, `APPLY MASKING POLICY` | `GOVERNANCE_ADMIN` |
| `EXECUTE TASK` | Each service role that owns a task |
| `CREATE DATABASE`, `CREATE WAREHOUSE` | `SYSADMIN` |

## 7. Decisions

### 7.1 IA-1: service-role granularity

**Options.** (a) One service role per publication unit, as tested. (b) One shared service role per project, for example `SVC_SILVER` owning every Silver unit's schemas.

| | (a) Role per unit | (b) Shared role |
|---|---|---|
| Blast radius of a defect | One unit. Observed: in S10 run 1 a selector defect made the ERP build select the Core models; it **failed safely** because the ERP role had no privilege on `core` | Every unit. The same defect would have rebuilt Core's models **directly into the published `silver.core`** (with `publish_unit: erp`, Core resolves to its published schema), bypassing the gate |
| Raw access | Each unit reads only its own source (F12) | Every unit's code can read every source |
| Input clones (IA-2) | Need a privilege model | No question: the shared role owns everything |
| Task layout (RC-1) | A task per unit; no single task graph | A single task graph becomes possible |
| Cost attribution | Per role, task and warehouse | Query tags only |
| Number of roles | One per unit (tens) | One per project |

**Recommendation: (a), a role per unit.** The S10 incident is the deciding evidence: per-unit ownership turned a code defect into a safe failure, which is the property publication is built on. The costs are manageable: roles are created by script from the `units` configuration, and input clones are handled by IA-2. A task graph is not needed at batch cadence (SLD 12.7). For Tier 1 and Tier 2 projects with one unit, a role per unit is a role per project.

**Decided 2026-10-09: (a)**, on condition that Silver stewards can create the roles for a new unit themselves, without an administrator (Section 7.1.1).

#### 7.1.1 Onboarding a unit (steward self-service)

Creating a role needs the account privilege `CREATE ROLE`, and granting the account privilege `EXECUTE TASK` needs `MANAGE GRANTS`. Neither should be a privilege that stewards use directly. Proposal: one owner's-rights procedure, `onboard_unit(unit)`, owned by a provisioning role *(new, `SILVER_PROVISIONER`)*, which stewards may call through `SILVER_OPERATOR`. It reads the unit's row in `units` and `unit_dependencies` (already reviewed by pull request, SLD 12.3), and then:

1. Creates the service role `SVC_SILVER_<UNIT>` (the provisioner owns it) and grants it to `SYSADMIN`.
2. Creates the reader database role `silver.reader_<unit>` and grants it to `silver.reader`.
3. Grants the access role `SILVER_UNIT_BASE` *(new)*, which holds the fixed set from Section 5.3: `CREATE SCHEMA` on the database, `USAGE` on the project object, the publish procedure and the run-control procedures, `SELECT` on configuration and status, and the warehouse. Object owners grant to `SILVER_UNIT_BASE` once; the provisioner, which owns it, grants it to each unit role. The provisioner therefore needs no grant option on anyone else's objects.
4. Grants an access role `TASK_RUNNER` *(new)*, which `SECURITYADMIN` created once with `EXECUTE TASK`. This is how the account privilege reaches new roles without `MANAGE GRANTS`.
5. Grants the reader roles of the unit's Silver upstreams (IA-2).
6. Creates the unit's published schema as the new role, `WITH MANAGED ACCESS`, grants schema `USAGE` to `silver.reader_<unit>`, inserts the lease row, and records an `ONBOARDED` event.

Two steps are outside the stewards' control by design:

- **Raw access** is granted by the platform team: `PLATFORM_INGEST` grants a raw reader database role for the source (for example `raw.reader_<source>`) to the new unit role. This is a platform step in the onboarding runbook.
- **Clear-value access** (`PII_CLEAR_<scope>`, Section 6.4) is granted by governance, if at all.

`offboard_unit(unit)` reverses it once a unit is retired. Both procedures, and the runbook steps around them, are part of the operations runbook (`docs/lld/README.md`). What the provisioner needs, and that an owner's-rights procedure can create roles and grant them, is verification item V-IA-9.

### 7.2 IA-2: input-clone privileges

A downstream unit (Core, and every Tier 1 and Tier 2 unit) clones its upstream units' published schemas at the gate (SLD 10.9). The clone needs privileges on every object, frozen inputs included (F6).

**Options.**

- **(a) Inherit the upstream unit roles** (as tested in S10). The downstream role can then alter, drop or swap the upstream units' schemas, and its dbt code runs with those privileges. Across ownership boundaries this does not work at all: a Tier 1 team's service role would inherit Silver unit roles and could write to Silver.
- **(b) An owner's-rights clone procedure** owned by `SILVER_CLONER`, a role with read access to every unit schema and used only by the procedure. For a unit `p_unit`, the procedure reads its upstreams from `unit_dependencies`, creates `<unit>__in_<upstream>` clones, grants `USAGE` on them to the unit's service role (looked up in `units`, not taken from the caller), and drops them after the run. Cloned objects keep their grants to the upstream's reader database role (F5); the downstream role holds those reader roles, so it reads exactly the **published** objects of each upstream it declared, and nothing else (not the frozen inputs, not internal models).
- **(c) A read-only role with `SELECT` on every object of every unit schema**, granted to downstream roles. Every object must carry the grant, including frozen inputs that the freeze recreates each run, internal models and snapshots; one missed object fails the clone (or worse, V-IA-3). Downstream roles can read upstream frozen inputs.

**Recommendation: (b).** The downstream unit gets consumer-level access to its declared upstreams, which is what SLD 9 and the Tier rules say it may read; the privilege needed to clone is confined to fixed procedure code that no dbt project and no person runs; and the same procedure serves Tier 1 and Tier 2 units reading Silver. What `SILVER_CLONER` itself holds is a sub-choice: inheriting the unit roles (simplest, but includes ownership) or `SELECT` grants maintained like option (c). Inheriting is acceptable because the role is reachable only through the procedure. Depends on V-IA-2 and V-IA-3.

**Decided 2026-10-09: (b).** The sub-choice for `SILVER_CLONER` is settled by the prototype (V-IA-2).

### 7.3 IA-3: reader database roles

**Options.** (a) One reader database role per database (`silver.reader`, as tested). (b) One per unit (`silver.reader_erp`), all granted to a per-database `silver.reader`.

**Recommendation: (b).** The swap sequence costs the same (one grantee per unit, F3). It allows consumers to be limited to particular sources, which a sensitive source (HR, for example) will need. And it makes IA-2 (b) exact: a downstream unit holds the reader roles of the upstreams in `unit_dependencies`, so its read access is derived from its declared dependencies. Consumers who should read everything hold `silver.reader`.

**Decided 2026-10-09: (b).** Sensitive sources are highly likely. Consequences:

- A sensitive source's reader role is **not** granted to `silver.reader`. It is granted to named consumer roles only, so "read all of Silver" never includes it by accident.
- A downstream unit that declares a sensitive upstream (for example Core reading an HR source) gets that source's reader role through `onboard_unit` like any other upstream. A dependency on a sensitive source therefore needs a steward-approved change to `unit_dependencies`, which makes it visible in review.
- Whether a source is sensitive is a column of `units` *(new: `sensitive boolean`)*, set by the stewards with governance.

### 7.4 IA-4: role hierarchy and administration

**Recommendation.**

- The layers of Section 5: system, owner, service, utility, CI and deploy, access (database roles and `PII_CLEAR`), functional. Every custom account role is granted to `SYSADMIN`.
- **Owner roles are not daily roles.** Changes to owned objects go through the deployment pipeline under the owner role; people use functional roles (`SILVER_OPERATOR`, developer and consumer roles). An administrator assumes an owner role only for set-up or break-glass.
- `USERADMIN` creates roles and users; `SECURITYADMIN` grants roles and account privileges; both through version-controlled scripts (principle 8). The tooling (SQL scripts run by CI, or a declarative tool) is part of CD-1.

### 7.5 IA-5: CI and deployment identities

**Recommendation.**

- **CI builds run as a CI role per repository** (`CI_SILVER`, `CI_<PROJECT>`), not as a unit role. In S6 CI ran as the ERP unit role, which could therefore have written to the ERP published schemas. A CI role owns only CI schemas, reads published upstream objects through reader roles (deferred relations), and, for Silver, reads raw to freeze its own inputs (S6: CI cannot use production frozen inputs). It reads raw masked unless governance grants clear access (Section 6.4).
- **Deployment runs under the project's owner role** by the CI user: `ADD VERSION` on the project object, `DEPLOYED` through `log_event`, registry rows through an owner's-rights procedure (CI-2).
- Depends on V-IA-4 (CI under its own role) and V-IA-5 (privileges for `ADD VERSION` and for `IMPORTS` of another object's artifacts).

### 7.6 IA-6: developer access

**Recommendation.** One developer role per project (`SILVER_DEVELOPER`, `<PROJECT>_DEVELOPER`), held by the people who work on it. It owns its development schemas (layout in EN-3), reads published upstream objects through reader roles and, for Silver, reads raw masked. It holds no service, owner or clear-PII role. Whether development needs clear values at all is GV-3.

### 7.7 IA-7: human access to service roles

**Recommendation.** No person holds a service role in production. Stewards operate through `SILVER_OPERATOR`: run-control views, `EXECUTE TASK` on a unit's task (the run is still the unit role's, F1, F2), the full-refresh procedure. Break-glass is a time-limited grant of a unit role to a named user by `SECURITYADMIN`, recorded and revoked. Depends on V-IA-7.

### 7.8 IA-8: authentication

Organisational: service and CI users authenticate with key pairs or workload identity federation, humans by SSO; network policies per user type. Not designed here.

## 8. Verification items

Small checks the recommendations depend on, none covered by the spikes. They can run on the trial account before it expires (about 2026-11-04).

| ID | Check | Needed by |
|---|---|---|
| V-IA-1 | dbt `grants` config grants `SELECT` to a **database role**, and the grant is reapplied correctly across clone and swap | 6.2, IA-3 |
| V-IA-2 | An owner's-rights procedure can `CREATE SCHEMA ... CLONE` an upstream unit schema and grant `USAGE` on it; who owns the cloned child objects; cloned objects keep their grants to the reader database role; a downstream role holding that reader role reads the published objects in the clone, including views over frozen inputs, and cannot read the frozen inputs themselves | IA-2 |
| V-IA-3 | A schema clone by a role lacking privileges on some child objects: does it fail, or skip them silently? | IA-2 (c), and as a safety property of (b) |
| V-IA-4 | A CI build under a dedicated CI role: freeze into the CI schema, `--defer` to published objects through reader roles, `IMPORTS` of the production object's canonical state | IA-5 |
| V-IA-5 | The privilege needed for `ALTER DBT PROJECT ... ADD VERSION` (owner only, or a grantable privilege) | IA-5 |
| V-IA-6 | Source tests on masked values in CI and development (uniqueness, relationships on a masked column) | 6.4, GV-3 |
| V-IA-7 | `OPERATE` on a task is enough for a person to run it with `EXECUTE TASK`, and the run is the owner's | IA-7 |
| V-IA-8 | `IS_ROLE_IN_SESSION` in a masking policy reveals to a service role that holds `PII_CLEAR_<scope>`, with secondary roles off, including inside a task and an `EXECUTE DBT PROJECT` run | 6.4, GV-3 |
| V-IA-9 | An owner's-rights procedure owned by `SILVER_PROVISIONER` creates a role, grants it privileges and `TASK_RUNNER`, creates a database role and grants it, and creates a schema as the new role (or hands it over); the least privileges `SILVER_PROVISIONER` needs | 7.1.1 |

## 9. Residual risks

- **`CREATE SCHEMA` cannot be scoped by name.** A unit role can create any schema in its database. Mitigated by code review and a periodic check that every schema in a unit database has the expected owner.
- **`SILVER_CLONER` is powerful.** Confined to one owner's-rights procedure with fixed SQL and inputs read from configuration; no person or dbt target uses it.
- **A missing or wrong classification tag is a silent leak** (S9f.B6): service roles read and store clear values. The CI tag check (component 2) remains the safety net, not the role model.

## 10. Questions for review

Answered 2026-10-09: IA-1, IA-2 and IA-3 decided (Section 7). The verification items run as part of the prototype (`docs/lld/README.md`, "Approach").

Open:

1. Section 6.4: the Core unit needs clear values for identity resolution. Is a `PII_CLEAR` access role, decided by governance, the right shape?
2. Section 7.1.1: is the onboarding procedure, with the platform and governance steps kept outside it, the right split of responsibility?
3. IA-4 to IA-7: the recommendations stand until reviewed.

## 11. Prototype

Increment 1 of the prototype (`prototype/README.md`) implements Sections 5, 7.1.1 and 7.3. Increments 2 to 5 cover the remaining verification items.

| Script | Implements |
|---|---|
| `prototype/01_identity/i1_10_foundation.sql` | Owner, utility, access and functional roles; account privileges; databases |
| `prototype/10_external/i1_20_platform_raw.sql` | Simulated raw sources, with platform-owned raw reader database roles |
| `prototype/06_run_control/i1_30_control_tables.sql` | `units` (with `sensitive`), `unit_dependencies`, `publish_log`, `unit_lease`, `log_event` |
| `prototype/01_identity/i1_40_provisioning.sql` | `onboard_unit`, `offboard_unit`, `grant_unit_reader`, `revoke_unit_reader` |
| `prototype/demo/i1_demo_onboarding.sql` | The demo, cases INC1.00 to INC1.41 (V-IA-9) |

**Result:** not yet run.

**Implementation choices to confirm at the increment 1 review:**

1. `SILVER_UNIT_BASE` carries the common privileges of unit roles (Section 7.1.1, step 3).
2. The provisioning procedures live in `silver.ops`, which is **not** managed access, so the provisioner can grant `USAGE` on the procedures it owns.
3. `onboard_unit` is also the way to **re-apply** a unit's grants (it is idempotent); it does not yet revoke reader roles of upstreams removed from configuration.
4. `offboard_unit` refuses while `unit_dependencies` names the unit as an upstream, and drops the unit's schemas (recoverable with `UNDROP` for their retention period). Removing the configuration rows is the ops-repository pull request.
5. New event types in `publish_log`: `ONBOARDED`, `OFFBOARDED`, `ACCESS_GRANTED`, `ACCESS_REVOKED` (an addition to SLD 12.2).
6. `grant_unit_reader` refuses service roles: a unit reads its upstreams only through `unit_dependencies`. Who approves access to a sensitive unit is a governance process step (GV-2, GV-3); the procedure logs every grant.
7. Raw access is a platform-owned database role per source (`raw.reader_<source>`), granted by the platform to the unit role as the last onboarding step.
