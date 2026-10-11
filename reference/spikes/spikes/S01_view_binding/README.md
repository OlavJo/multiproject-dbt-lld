# S1: View-relative resolution across swap and clone

**Status:** **complete** (2026-10-05, two runs). Plain views **pass**. Semantic views **fail** with bare names; the published-name rule (Part E) **passes**. **Load-bearing:** yes (SLD 10.5).

## Question

Publication builds a unit in `<unit>__build` and swaps it into place with `ALTER SCHEMA ... SWAP WITH`. dbt renders fully qualified names, so a view built in the build schema would keep pointing at the build schema after the swap, and read stale objects.

The SLD relies on the Snowflake documentation statement that "all unqualified objects in a view or UDF definition will be resolved in the view's or UDF's schema only". If same-schema references from views are rendered as bare identifiers, then:

1. `CREATE VIEW` must accept the bare identifier.
2. Binding must happen at query time, against the view's **current** schema, so that after a swap the view under the published name reads its siblings under the published name.
3. A **schema clone** must rebind cloned views to the cloned siblings (relied on by SLD 10.4 step 2 and the S10 mitigation in SLD 10.9).
4. The same must hold for Snowflake semantic views (SLD 10.7 rule 2).

## Method

`s01_view_binding.sql`, run as `SVC_SILVER_ERP`. Each table `T` carries a one-row `marker` value, so whichever `T` a view resolves to is visible in its output. The session schema is set to a decoy schema containing its own `T` (marker `OTHER`) throughout, so resolution against the session rather than the view's schema would be detected.

| Part | Cases | What is exercised |
|---|---|---|
| A | S1.01 to S1.07 | Creation with bare identifiers; resolution against the view's schema, not the session; stored DDL; no fallback to the session schema; semantic views |
| B | S1.10 to S1.13 | Schema clone: cloned views and semantic views read the clone's `T` |
| C | S1.20 to S1.26 | Publication cycle (clone, rebuild, swap) as SLD 10.4; a fully qualified **control** view showing the hazard; a cross-unit fully qualified view |
| D | S1.30 to S1.32 | Second cycle where views are not recreated, only cloned |
| E | S1.40 to S1.44 | (Added after run 1) Semantic views referencing the **published** table name: atomic publication, and the new-column limitation |

Expected values are what the SLD predicts. A `FAIL` is a finding.

## Result

### Run 1 (2026-10-05, `evidence/S1_20261005.csv`)

**Plain views: PASS on every case. Observed.**

| Case | Expected | Observed | Outcome |
|---|---|---|---|
| S1.01 | created | View V successfully created. | PASS |
| S1.02 | OLD | OLD (session schema was the decoy) | PASS |
| S1.03 | bare `t` stored | `... as select id, marker from t;` | PASS |
| S1.04 | error | `Object 'SILVER.S1_PUB.U' does not exist` (looked up in the view's schema only) | PASS |
| S1.10, S1.11 | CLONED | CLONED | PASS |
| S1.20 | OLD | OLD | PASS |
| **S1.21** | **NEW** | **NEW** | **PASS** |
| S1.22 | NEW | NEW | PASS |
| S1.24 | OLD | OLD | PASS |
| S1.25 (control, fully qualified) | OLD | OLD | PASS |
| S1.26 | OTHER | OTHER | PASS |
| S1.30 | NEWER | NEWER | PASS |
| S1.32 | NEW | NEW | PASS |

**Semantic views: FAIL. Observed.**

| Case | Expected | Observed | Outcome |
|---|---|---|---|
| S1.05 | created | Semantic view SV successfully created. | PASS |
| S1.06 | OLD | **OTHER** (the decoy session schema's table) | FAIL |
| S1.07 | (info) | stored as `tables ( SILVER.S1_OTHER.T primary key (ID) )` | INFO |
| S1.12 | CLONED | OTHER | FAIL |
| S1.23 | NEW | OLD | FAIL |
| S1.31 | NEWER | NEW | FAIL |

### Run 2 (2026-10-05, `evidence/S1_20261005_2.csv`)

Script changes: decoy session schema re-asserted after every `CREATE SCHEMA`; Part E added.

- Plain-view cases: identical to run 1, all PASS.
- S1.06, S1.12: `OTHER`, as in run 1.
- **S1.23 and S1.31: now `OTHER`** (run 1: `OLD`, `NEW`). With the decoy in force throughout, semantic views always bind to the session schema at creation. This confirms the run 1 explanation.

| Case | Expected | Observed | Outcome |
|---|---|---|---|
| S1.40 | created | Semantic view SV_PUB successfully created. | PASS |
| S1.41 | NEWER (published, before swap) | NEWER | PASS |
| **S1.42** | **E_NEW (after swap)** | **E_NEW** | **PASS** |
| S1.43 | (info) | stored as `tables ( SILVER.S1_PUB.T primary key (ID) )` | INFO |
| S1.44 | error | `invalid identifier 'EXTRA'` | PASS |

### Interpretation

1. **Plain views bind at query time, in the view's own schema.** The stored text keeps the bare identifier (S1.03); resolution ignores the session schema (S1.02) and does not fall back to it (S1.04); after a swap the view under the published name reads its new siblings (S1.21, S1.22); a schema clone rebinds cloned views to the clone's siblings (S1.10, S1.11), including views that were cloned but not recreated (S1.30). A fully qualified view reads the stale build after the swap (S1.25), which is the hazard SLD 10.5 removes.
2. **Semantic views resolve bare table names at creation, against the session's current schema, and store them fully qualified** (S1.07: `SILVER.S1_OTHER.T`). They are therefore not swap-safe with bare names. S1.06 and S1.12 read the decoy; S1.23 and S1.31 behave like the fully qualified control, following the build schema name.
3. **`CREATE SCHEMA` switches the session's current schema** to the new schema. In run 1 the decoy was therefore in force for Part A only; in Parts C and D the session was `s1_build` when the semantic view was created, so it stored `SILVER.S1_BUILD.T` (S1.23 `OLD`, S1.31 `NEW`). Run 2 kept the decoy in force and both read `OTHER`. The plain-view conclusions hold in both runs.
4. **Semantic views that reference the published name publish atomically** (S1.40 to S1.43). In the build schema they read the currently published tables; after the swap they sit under the published name and read the newly published tables.
5. **Semantic view columns are validated at creation** against the referenced table (S1.44). A published-name semantic view cannot use a column or table that is new in the same build.

## Effect on the design

- **SLD 10.5 confirmed for plain views; the SLD 10.6 contingency is not needed.** Base views over frozen inputs with bare same-schema references are swap-safe and clone-safe.
- **SLD 10.7 rule 2 must not include semantic views.** Replacement rule, **observed to work** (Part E): semantic views built in a unit's build schema reference the **published** names of their tables (fully qualified), so after the swap they read the newly published tables, atomically with the unit.
- **Observed limitation** (S1.44): such a semantic view cannot use a column or table that is new in the same build, because columns are validated at creation. Options for the LLD: (a) release the column first and the semantic view change in the next publication; (b) recreate the affected semantic views in the published schema immediately after the swap (not atomic, and needs `CREATE SEMANTIC VIEW` on the published schema at publish time); (c) on first publication of a unit, create its semantic views after the first swap.
- **dbt rendering.** The `ref` override (SLD 10.5) must render semantic-view references as the published relation name, not the build name and not a bare name. This affects how the Snowflake-Labs `dbt_semantic_view` package is used (Overview 10, "To confirm").
- **Scripts must not rely on the session schema** for anything that binds at creation. `CREATE SCHEMA` changes it silently.
