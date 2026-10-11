# S2: Swap and grants

**Status:** **complete** (2026-10-05). Schema `USAGE` moves with the schema, so the publish step is grant, swap, revoke. A plain clone drops managed access; `CLONE ... WITH MANAGED ACCESS` keeps it.

## Question

SLD 10.7 rule 5: consumers are granted object by object (dbt `grants` config on published models), never on build schemas, and never by future grants. Snowflake documents that `SWAP WITH` "also swaps all access control privileges granted on the schemas". Two readings are possible:

- **Stays with the name**: schema `USAGE` granted on `silver.erp` remains on the published name after the swap. No re-grant is needed.
- **Moves with the schema**: `USAGE` moves to `silver.erp__build`. The publish procedure must then grant `USAGE` on the build schema just before the swap and revoke it from the new build schema just after.

Also to establish:

- Per-object grants are copied by the schema clone, and travel with the swap.
- Consumers never gain access to a build schema, or to internal objects.
- Behaviour in **managed-access** schemas (SLD 16 open item), where only the schema owner can grant.
- Grants to a **database role** (`SILVER.READER`) rather than an account role.

## Method

`s02_swap_grants.sql`. The unit service role `SVC_SILVER_ERP` owns both schemas and runs the cycle. The consumer `ANALYST_TIER1` holds only the database role `SILVER.READER`. Every consumer read is made as the consumer role, with secondary roles disabled.

| Variant | Cases | Sequence |
|---|---|---|
| A | S2.01 to S2.13 | Standard schema: clone, rebuild with grant, plain swap. Schema grants recorded before and after |
| B | S2.20 to S2.21 | Standard schema: grant `USAGE` on build, swap, revoke from the new build schema |
| C | S2.29 to S2.34 | Managed-access schemas, plain swap (S2.29 and S2.34 added after run 1) |
| D | S2.40 to S2.45 | (Added after run 1) Managed access re-enabled on the build schema, then the variant B grant sequence |
| E | S2.50 to S2.57 | (Added after run 2) Build schema created as a managed-access clone in one statement, then the grant sequence. Self-contained block |

**Not observable by this script:** whether there is a window with no consumer access during the swap. The swap itself is a single atomic statement. In variant B, the consumer has `USAGE` on the build schema between the grant and the swap (where the build holds the tested new version) and between the swap and the revoke (where it holds the previous version). If variant A passes, variant B is unnecessary and the question does not arise.

## Result

### Run 1 (2026-10-05, `evidence/S2_20261005.csv`)

| Case | Expected (HLD) | Observed | Outcome |
|---|---|---|---|
| S2.01 | V1 | V1 | PASS |
| S2.02 | error | not authorized (internal table) | PASS |
| S2.03 | (info) build schema grants after clone | `OWNERSHIP -> SVC_SILVER_ERP` only | INFO |
| S2.04 | SELECT copied to cloned child | `SELECT -> DATABASE_ROLE READER` present | PASS |
| S2.05, S2.06 | error | no `USAGE` on `SILVER.S2__BUILD` | PASS |
| S2.07 | V1 | V1 | PASS |
| S2.08 | (info) published name after swap | `OWNERSHIP -> SVC_SILVER_ERP` only | INFO |
| S2.09 | (info) build name after swap | `OWNERSHIP`; **`USAGE -> DATABASE_ROLE READER`** | INFO |
| **S2.10** | **V2** | **no `USAGE` on `SILVER.S2`** | **FAIL** |
| S2.11 | V1 | no `USAGE` on `SILVER.S2` | FAIL |
| **S2.12** | error | **V1** (consumer reads the previous version in the build schema) | **FAIL** |
| S2.13 | error | error (no schema access at all) | PASS |
| **S2.20** | **V2** | **V2** | **PASS** |
| **S2.21** | error | no `USAGE` on `SILVER.S2__BUILD` | **PASS** |
| S2.30 | MANAGED ACCESS | empty `options` (no control case; see run 2) | FAIL |
| S2.31 | grant succeeds | succeeded | PASS |
| S2.32 | V2 | no `USAGE` on `SILVER.S2M` | FAIL |
| S2.33 | error | V1 | FAIL |

### Run 2 (2026-10-05, `evidence/S2_20261005_2.csv`)

Variants A to C repeat run 1 exactly. New cases:

| Case | Expected | Observed | Outcome |
|---|---|---|---|
| S2.29 (control) | MANAGED ACCESS | MANAGED ACCESS | PASS |
| **S2.30** | MANAGED ACCESS | **`<none>`** | **FAIL** |
| **S2.34** | MANAGED ACCESS | **`<none>`** (published schema after swap) | **FAIL** |
| **S2.40** | `ENABLE MANAGED ACCESS` succeeds | **`must have MANAGE GRANTS granted on ACCOUNT`** | **FAIL** |
| S2.41, S2.42 | MANAGED ACCESS | `<none>` (consequence of S2.40) | FAIL |
| S2.43 | V2 | V2 | PASS |
| S2.44, S2.45 | error | error | PASS |

### Variant E (2026-10-05, `evidence/S2E_20261005.csv`)

| Case | Expected | Observed | Outcome |
|---|---|---|---|
| **S2.50** | accepted | `Schema S2E__BUILD successfully created.` (`CREATE OR REPLACE SCHEMA ... CLONE ... WITH MANAGED ACCESS`, as `SVC_SILVER_ERP`) | **PASS** |
| S2.51 | MANAGED ACCESS | MANAGED ACCESS | PASS |
| S2.52 | accepted | syntax error (`WITH MANAGED ACCESS` before `CLONE`) | FAIL |
| S2.53 | | no row: the S2.52 schema was not created, so `SHOW SCHEMAS` returned nothing to record | |
| **S2.54** | MANAGED ACCESS | **MANAGED ACCESS** (published schema after swap) | **PASS** |
| S2.55 | V2 | V2 | PASS |
| S2.56, S2.57 | error | error | PASS |

### Interpretation

1. **Schema-level privileges move with the schema object, not with its name** (S2.08, S2.09). After `ALTER SCHEMA b SWAP WITH p`, the `USAGE` previously granted on `p` is now on the schema named `b`.
2. **A plain swap therefore causes an outage and a leak at once.** Consumers lose access to the published name entirely (S2.10, S2.11, S2.32) and gain access to the previous version under the build name (S2.12, S2.33).
3. **Object-level grants behave as designed.** A schema clone copies grants on child objects (S2.04); internal objects with no grants stay invisible (S2.02, S2.13).
4. **The SLD 10.7 rule 5 fallback works** (variant B): `GRANT USAGE` on the build schema, `SWAP`, `REVOKE USAGE` from the new build schema. Consumers read the new version with no gap and lose access to the build schema (S2.20, S2.21).
5. **Exposure windows in variant B** (reasoned, not observable in one session): between the grant and the swap, consumers can read the build schema, which holds the new, fully tested version; between the swap and the revoke, they can read the previous version, which they were reading until the swap. No untested data is exposed. Each window is one statement long.
6. **A schema clone does not inherit managed access** (run 2: S2.29 control PASS, S2.30 `<none>`). After the first publication by clone and swap, **the published schema is no longer managed access** (S2.34).
7. **`ALTER SCHEMA ... ENABLE MANAGED ACCESS` requires `MANAGE GRANTS` on the account**, even for the schema's owner (S2.40). Granting `MANAGE GRANTS` to a unit service role would give it grant authority over every object in the account; not acceptable.
8. **The grant sequence is independent of managed access** (S2.43 to S2.45).
9. **`CREATE OR REPLACE SCHEMA <build> CLONE <published> WITH MANAGED ACCESS` keeps managed access without `MANAGE GRANTS`** (S2.50, S2.51), and the published schema remains managed access after the swap (S2.54). Clause order matters: `WITH MANAGED ACCESS` must follow `CLONE <source>` (S2.52).

## Effect on the design

- **SLD 10.4 step 5 and 10.7 rule 5:** the publish procedure must use the grant sequence `GRANT USAGE ON SCHEMA <unit>__build` → `SWAP` → `REVOKE USAGE ON SCHEMA <unit>__build`. The "stays with the name" reading is refuted.
- The grant and revoke must be on **every** grantee of the published schema's `USAGE`. With consumers granted through database roles (one `SILVER.READER` per database, or one per unit), that is one or a few statements; the LLD should keep it that way rather than granting schema `USAGE` to many account roles.
- The revoke must run on every exit path after a successful swap, including when the canonical-state step fails (SLD 10.4 step 6).
- **Managed access is kept by cloning with `WITH MANAGED ACCESS`** (variant E). `CLONE` followed by `ENABLE MANAGED ACCESS` is not an option, because `ENABLE` needs `MANAGE GRANTS` on the account.

### Publish step, as observed to work (replaces SLD 10.4 steps 2 and 5)

```sql
-- step 2: clone last good state, keeping managed access
create or replace schema <db>.<unit>__build clone <db>.<unit> with managed access;

-- steps 3 and 4: freeze, build, test (dbt applies per-object grants on published models)

-- step 5: atomic publish with the grant sequence
grant  usage on schema <db>.<unit>__build to database role <db>.<reader>;
alter schema <db>.<unit>__build swap with <db>.<unit>;
revoke usage on schema <db>.<unit>__build from database role <db>.<reader>;
```

The unit's published schema is created `WITH MANAGED ACCESS` once, when the unit is set up. The revoke must run on every exit path after a successful swap.
