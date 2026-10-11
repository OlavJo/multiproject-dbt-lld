# S9 (visibility half): frozen inputs, classification carry-over, masking

**Status:** visibility half and S9b **complete** (2026-10-05). The retained-storage half follows separately. The retained-storage half of S9 needs elapsed time and churn on raw; it follows separately.

## Question

From SLD 6.3, 7 and 10.7:

1. The freeze clones every raw table of a source **at the unit watermark**, as a transient table. Does `CLONE ... AT (TIMESTAMP => watermark)` give exactly the rows as of the watermark, when the watermark is stored, as run control stores it, as UTC `TIMESTAMP_NTZ`? Does the session timezone matter?
2. Frozen inputs are never granted to consumers. Do they stay invisible after clone and swap?
3. Masking policies and tags on raw are documented to carry over to clones. Are consumers masked when reading a base view over a frozen input?
4. Materialised tables do **not** inherit raw's masking (SLD 6.3), so every derived column must carry the classification tag. Is that premise right, and does an explicit post-hook fix it?
5. **New since the HLD:** Snowflake's automatic tag propagation (`PROPAGATE = ON_DATA_MOVEMENT`) is documented to carry tags onto CTAS and DML targets. Can it replace the post-hook and the CI check?

## Method

`setup/05_governance.sql` creates `GOVERNANCE_ADMIN`, two tags and two masking policies (clear values for `PLATFORM_INGEST` and `SVC_SILVER_ERP` only):

- `PII`: plain tag, the SLD 6.3 approach.
- `PII_AUTO`: `PROPAGATE = ON_DATA_MOVEMENT`.

`s09_frozen_inputs.sql`: the platform role creates `raw.erp.customers` with `email` tagged `PII` and `phone` tagged `PII_AUTO`, records a watermark, then lands a late row. The unit service role freezes, builds and publishes one unit with the S2 publish step.

| Part | Cases | What is exercised |
|---|---|---|
| B | S9.00 to S9.15 | Clone at a UTC NTZ watermark under the default session timezone, then with `TIMEZONE = UTC`; row counts; transient kind |
| D | S9.20 to S9.26 | Tags on the frozen input, on a CTAS without post-hook, with post-hook, and propagated; frozen-input grants; control read by the service role |
| E | S9.30 to S9.38 | What `ANALYST_TIER1` can read, and whether each column is masked |

## Result

### Run 1 (2026-10-05, `evidence/S9_20261005.csv`): all cases PASS

| Case | Expected | Observed |
|---|---|---|
| S9.00 | (info) | session timezone `America/Los_Angeles` |
| S9.10, S9.11 | (info) | clone `AT` a UTC NTZ watermark under the default timezone: created, **3 rows** |
| S9.12, S9.13 | 3 rows | with `TIMEZONE = UTC`: created, **3 rows** |
| S9.14 | 4 | 4 (live raw includes the late row) |
| S9.15 | TRANSIENT | TRANSIENT |
| S9.20, S9.21 | tags on the frozen input | `email`, `phone` |
| S9.22 | no `PII` tag after CTAS | `<NULL>` |
| S9.23 | post-hook tag | `email` |
| **S9.24** | **`PII_AUTO` propagated by CTAS** | **`phone`** |
| S9.25 | ownership only | `OWNERSHIP -> ROLE SVC_SILVER_ERP` |
| S9.26 | clear (service role) | `ana@example.com` |
| S9.30, S9.31 | error | not authorized (frozen input; raw database) |
| S9.32 | 3 | 3 |
| **S9.33**, S9.34 | masked via base view | `***MASKED***` |
| S9.35, S9.36 | masked in built table | `***MASKED***` |
| **S9.37** | clear without post-hook (hazard) | **`ana@example.com`** |
| **S9.38** | masked by propagation, no post-hook | **`***MASKED***`** |

## Interpretation

1. **`CLONE ... AT (TIMESTAMP => <TIMESTAMP_NTZ>)` interprets the NTZ value as UTC, independent of the session timezone** (S9.10, S9.11 under `America/Los_Angeles`; S9.12, S9.13 under UTC). The result is conclusive: an interpretation in Los Angeles time would shift the watermark by 7 hours, placing it in the future or before the table existed, and the clone would fail. The freeze can use run control's UTC NTZ watermarks directly.
2. **The freeze works as SLD 7 specifies**: a transient clone holding exactly the rows as of the watermark, while a late row is visible in live raw.
3. **Frozen inputs are invisible to consumers**: a table clone does not copy the source's grants (S9.25), and nothing grants them (S9.30).
4. **Masking carries through clones and base views** (S9.20, S9.21, S9.33, S9.34). The Silver service role reads clear values (S9.26), as SLD 6.3 assumes.
5. **SLD 6.3's premise is confirmed**: `CREATE TABLE AS SELECT` does not carry a plain tag (S9.22), and the derived column is then readable in clear by consumers (S9.37).
6. **Automatic tag propagation (`PROPAGATE = ON_DATA_MOVEMENT`) carries the tag and its masking onto a CTAS target with no post-hook** (S9.24, S9.38). Observed within the 10 s wait in the script.

## Effect on the design

- SLD 7 (frozen inputs) confirmed. No session-timezone rule is needed for the freeze; setting `TIMEZONE = 'UTC'` for service users remains good practice for readable logs.
- SLD 6.3's hazard is real. **Candidate simplification:** classification tags created with `PROPAGATE = ON_DATA_MOVEMENT` by the governance team would make the dbt post-hook unnecessary, and turn the CI check into a safety net rather than the primary control. Before the LLD adopts it, S9b tests: incremental `MERGE` and `INSERT` targets, columns transformed by expressions, columns arriving through joins, and conflicting tags.
- Propagation is configured by the governance team (account-level `APPLY TAG`, setup/05), consistent with the role split.

## S9b: limits of automatic tag propagation

**Status:** complete (2026-10-05, `evidence/S9b_20261005.csv`).

S9 showed propagation works for a plain CTAS copy of a tagged column. Before the LLD relies on it instead of the post-hook, S9b covers what dbt models actually do:

| Table | Pattern | Why it matters |
|---|---|---|
| T1 | CTAS of zero rows, then `MERGE` insert and `MERGE` update | dbt incremental models: first build, then merges |
| T1b | `MERGE` into a table created with explicit columns | control for T1 without any CTAS |
| T2 | `INSERT ... SELECT` into an existing table | incremental `append` strategy |
| T3 | `lower`, `sha2`, `left`, `length`, `coalesce`, concatenation with a literal | typical shaping of PII columns |
| T4 | tagged columns arriving through a join | entity models (SLD 6.5) |
| T5 | one column combining two differently tagged columns | `ON_CONFLICT` behaviour |
| T6 | `count(distinct)`, `max` | aggregates |

For each table, every column's tags are recorded with `TAG_REFERENCES_ALL_COLUMNS`, immediately and after 10 seconds; the full rows (including how each tag was applied) are kept in `DETAIL`. Then the consumer reads key columns. Expected values are given only where Snowflake documents the behaviour (DML propagation, joins); expressions, conflicts and aggregates are recorded as observed.

### S9b result

Tags recorded with `TAG_REFERENCES_ALL_COLUMNS`; every tag below has `APPLY_METHOD = PROPAGATED`. Immediate and 10-second readings were identical for every table.

| Table | Pattern | Tags on derived columns | Consumer sees |
|---|---|---|---|
| T1 | CTAS of zero rows, `MERGE` insert, `MERGE` update | `PHONE = PII_AUTO:phone` | masked (inserted and updated rows) |
| T1b | `MERGE` into a DDL-created table | `PHONE = PII_AUTO:phone` | masked |
| T2 | `INSERT ... SELECT` | `PHONE = PII_AUTO:phone` | masked |
| T3 | `lower`, `sha2`, `left`, `coalesce`, `'x' \|\| phone` | all `PII_AUTO:phone` | **masked**, including `sha2` |
| T3 | `length(phone)` (NUMBER) | `PII_AUTO:phone` | **`14`, in clear**: the tag's only masking policy is for strings |
| T4 | join | `PHONE = phone`, `ALT_PHONE = alt_phone` | masked |
| T5 | `phone \|\| alt_phone` (two values of one tag) | `PII_AUTO:CONFLICT` | masked |
| T6 | `count(distinct phone)`, `max(phone)` | both `PII_AUTO:phone` | `max` masked (count not read) |

### S9b interpretation

1. **Propagation covers every write pattern dbt uses** on Snowflake: CTAS, `MERGE` (insert and update) and `INSERT ... SELECT`, including into tables created by DDL, and through joins.
2. **Propagation is synchronous** in these tests: tags are present as soon as the statement completes.
3. **Propagation follows lineage, not meaning.** Every expression of a tagged column is tagged, including hashes, lengths and counts. Combining two values of one tag yields `CONFLICT`, which still triggers the tag's masking policy.
4. **Masking applies per data type.** A tagged column whose type has no policy on the tag is returned in clear (T3 `length`).

### S9b effect on the design (SLD 6.3)

- **Replace explicit tag carry-over with propagation.** Classification tags are created by the governance team with `PROPAGATE = ON_DATA_MOVEMENT`. The dbt post-hook is no longer needed to carry tags; the CI check becomes a safety net.
- **Every classification tag carries a masking policy for every data type in use** (at least string, number, date, timestamp). Otherwise derived non-string columns are tagged but unmasked (T3 `length`).
- **Declassification becomes the explicit act.** Propagation over-classifies by design (hashes, counts). Where a derived column is genuinely not sensitive, removing or overriding its tag must be a reviewed change, so the default fails closed. Whether a manual override on a target column survives subsequent `MERGE` statements is **not yet tested**; it is needed before the LLD specifies the declassification mechanism.
- **Interaction with views:** the tags use `ON_DATA_MOVEMENT` only. Views over tagged columns are masked through their source (S9.33), so `ON_DEPENDENCY` is not needed, and avoiding it avoids double policy evaluation noted in Snowflake's documentation.

## S9c: retained storage from replaced transient clones (trend only)

**Status:** complete as a trend (2026-10-06 run, metrics read about 3 hours later, `evidence/S9c_20261006.csv`). One effect needs more than a day to show (see below).

**Run 1 observed:** `INFORMATION_SCHEMA.TABLE_STORAGE_METRICS` returned no rows for any role on this account, so the in-script snapshots are empty and were not usable. A clone takes the **retention period of the schema it is created in**, not raw's (S9c.00: 0 in `S9C_RET0`, 1 in `S9C_RET1`). Retained bytes are read from `ACCOUNT_USAGE.TABLE_STORAGE_METRICS` after its latency, which shows replaced clones as separate rows.

**Question (SLD 7.4, SLD 14 S9).** Each unit run replaces its frozen inputs with fresh clones of raw. Micro-partitions that raw has since rewritten, and that only the replaced clone still references, are retained for Time Travel. How much is retained per run, and does a short retention period on the Silver schema contain it?

**Method.** Elapsed time is not what is being measured: the bytes retained depend on how much raw churns between freezes and on the retention period, and `INFORMATION_SCHEMA.TABLE_STORAGE_METRICS` reports them without the latency of `ACCOUNT_USAGE`. The script therefore runs in a few minutes:

- two synthetic raw tables of 2,000,000 rows, one rewritten 10% per cycle across all partitions (worst case), one rewritten in its last 5% only (append-like);
- two Silver schemas, retention 1 day and 0 days;
- 6 cycles of churn then re-freeze at a UTC NTZ watermark, with storage snapshots after each (raw, and both Silver schemas);
- also records the retention period a clone actually takes (the schema's, or raw's).

Production volumes are out of scope; the result is a trend: retained bytes per cycle as a share of table size, for the two churn shapes, and with and without a retention period.

## S9d: does a manual tag override survive later DML?

**Status:** script ready, not yet run. `s09d_tag_override.sql`. Closes the S9b open item and decides the declassification mechanism for SLD 6.3.

Two overrides on a propagated tag (`SET` another value, `UNSET`) are followed by the DML a dbt model performs: `MERGE` (update and insert), `INSERT ... SELECT`, a managed-access schema clone (the publish step) and a full-refresh `CREATE OR REPLACE TABLE AS SELECT`. After each, the tag on the column and what a consumer reads are recorded.

### S9d result (run 2026-10-06, `evidence/S9d_20261006.csv`): 47 statements ran; 2 PASS, rest INFO

| Override | After later DML | Consumer |
|---|---|---|
| **SET** a new value on the propagated tag (`PII_AUTO:reviewed:MANUAL`, S9d.11) | Survives `MERGE` (S9d.30), `INSERT ... SELECT` (S9d.40) and a managed-access schema clone (S9d.50). **Lost on full-refresh CTAS**: back to `PII_AUTO:phone:PROPAGATED` (S9d.60) | **Still masked** (S9d.32): the masking policy is attached to the tag, so any value masks |
| **UNSET** the tag (S9d.20, S9d.21: count 0) | **Not durable.** The next `MERGE` re-applies the tag (S9d.31: 1), and it stays through `INSERT`, clone and CTAS (S9d.41, .51, .61) | Clear while unset (S9d.22: `+64 21 000 001`), **masked again after the next MERGE** (S9d.33) |

Interpretation:

1. **A tag can be overridden on a propagated column, but the override only changes the tag's value.** It survives incremental DML and the publish clone, and a full refresh resets it (fails closed).
2. **UNSET cannot be the declassification mechanism**: propagation re-applies the tag on the next DML (observed after a `MERGE`; whether a background process or the DML does it was not separated). This fails closed: a declassification by UNSET quietly reverts, and the column is masked again.
3. **Changing the value does not unmask**, because the policy is attached to the tag, not to a value.
4. **Candidate mechanism (S9e):** a masking policy that reveals the value when the column's tag value is a reserved one (for example `declassified`), via `SYSTEM$GET_TAG_ON_CURRENT_COLUMN`. SET survives MERGE, INSERT and clone; a full refresh reverts it to masked, so the declassification list must be re-applied by a post-hook after a full refresh.
5. Caution about the note in S9d.22: a consumer read clear data for the moment between UNSET and the next MERGE; any UNSET-based flow would be exposed in that window.

## S9e: declassification by a reserved tag value

**Status:** complete (2026-10-06, `evidence/S9e_20261006.csv`): all 11 cases with an expectation PASS.

A masking policy on a propagating tag (`PII_DECL`) reveals the column when `SYSTEM$GET_TAG_ON_CURRENT_COLUMN` returns the reserved value `declassified`.

| Case | Observed |
|---|---|
| S9e.01, S9e.02 | Tag propagated (`PII_DECL:phone:PROPAGATED`); consumer masked |
| S9e.10, S9e.11 | `SET TAG ... = 'declassified'` on the target column; consumer reads clear |
| S9e.20 to S9e.23 | Survives `MERGE` (update and insert) and `INSERT ... SELECT`: tag stays `declassified:MANUAL`, consumer clear |
| S9e.30, S9e.31 | Survives the managed-access schema clone (publish step) |
| S9e.32 | **Full-refresh CTAS reverts to masked** (fails closed) |
| S9e.40 | A role without `APPLY` on the tag cannot declassify (`Insufficient privileges to operate on tag`) |

Design effect (SLD 6.3):

- Declassification is **a tag value set on the target column**, honoured by a value-aware masking policy owned by governance. It is durable across incremental runs and publication, and reverts to masked after any rebuild of the table.
- A full refresh (or any `CREATE OR REPLACE`) therefore needs the declassification re-applied. A dbt post-hook driven by a reviewed declassification list does this; the window between rebuild and post-hook is masked, not clear.
- Who may declassify is the privilege `APPLY` on the tag. The unit role holds it here only as a control. The LLD must decide whether declassification stays with governance (holding `APPLY` and a privilege on the target object) or is delegated to stewards, and keep the reviewed list in version control.
- A policy that calls `SYSTEM$GET_TAG_ON_CURRENT_COLUMN` is accepted on this account.

## S9f: tag propagation through a view

**Status:** complete (2026-10-06, `evidence/S9f_20261006.csv`). Follow-up to the P2 smoke test, where a table built from a base view over a frozen input showed PII in clear (P2.S1.13, P2.S2.13).

| Case | Observed |
|---|---|
| S9f.A1, A2 | `PII_DECL:email:MANUAL` on `raw.erp.accounts.email` and on the frozen input |
| **S9f.A3, A4** | **No tag** on the base view `stg_erp__accounts.email` or the table `erp_accounts.email` built from it |
| S9f.B1 | Frozen clone of a source with two tags: both carried (`PII_DECL`, `PII_DEP`; clone carries tags as `MANUAL`) |
| **S9f.B2** | The view column carries **`PII_DEP:email:PROPAGATED`** (tag with `PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT`); the `PII_DECL` column carries nothing |
| **S9f.B3** | The CTAS table built from the view carries `PII_DEP` as `PROPAGATED`; the `PII_DECL` column carries nothing |
| S9f.B4, B5 | Consumer reads the view: both columns masked (`***masked***` in lower case for the control column: the view applies `lower()` to the already masked value) |
| **S9f.B6** | **Consumer reads the control table column in clear** (`a@example.com`): the CTAS ran as the service role, which the policy reveals, and no tag came with it |
| **S9f.B7** | Consumer reads the candidate column masked |

Interpretation:

1. **`ON_DATA_MOVEMENT` does not cross a view**: the view's columns carry no tag, so a table created from the view has nothing to inherit. Base views (SLD 6.2) are in the chain of every Silver table, so classification tags on raw must use **`ON_DEPENDENCY_AND_DATA_MOVEMENT`**.
2. With dependency propagation, a view column takes the tag (`PROPAGATED`), and so does a table built from it. Masking is enforced at the view and at the table.
3. A `CTAS` run by the service role stores clear values: the table is protected only by the propagated tag, never by the policy at build time. A wrong or missing tag is therefore a silent leak, and the CI check (SLD 6.3) stays as the safety net.
4. Design effect: the Silver classification tags (`PII_DEP` in the spikes; setup/05) are created with `PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT`, carry the S9e value-aware policy, and replace the `meta` post-hook.


### S9c result (`evidence/S9c_20261006.csv`, `ACCOUNT_USAGE.TABLE_STORAGE_METRICS`, about 3 hours after 6 cycles of churn and re-freeze)

| Table | Active MB | Time Travel MB | Retained for clone MB |
|---|---|---|---|
| `RAW.ERP.S9C_SCATTERED` (10% of rows rewritten per cycle, scattered) | 97.0 | **567.4** | 0.0 |
| `RAW.ERP.S9C_CLUSTERED` (last 5% rewritten per cycle) | 93.8 | **167.9** | 0.0 |
| `SILVER.S9C_RET1.*` (retention 1 day): 6 replaced clones plus the live clone, per table | 0.0 | **0.0** | 0.0 |
| `SILVER.S9C_RET0.*` (retention 0): the same | 0.0 | **0.0** | 0.0 |

Observed:

1. **Replaced frozen clones held no storage of their own**, with a 1-day or a 0-day retention, at this time scale: every clone version (live and replaced) shows 0.0 MB active, Time Travel and retained-for-clone. The micro-partitions a clone shares with raw are accounted to raw.
2. **The storage cost sits on raw, as Time Travel bytes of the rewritten partitions**: 5.8 times the table's size for the scattered churn (6 cycles, nearly every partition rewritten each time) and 1.8 times for the clustered churn. That cost exists whether or not anyone clones raw: the freeze needs Time Travel on raw to clone `AT` a watermark (SLD 4.1), so raw's retention is at least the platform's choice, and the clones add nothing on top within that period.
3. **The `RET1` and `RET0` schemas behaved the same** so far. The replaced versions of `RET1` remain visible for their 1 day; those of `RET0` were dropped at once (the listing shows them as `DELETED`, with a drop time seconds after creation, as expected, and with no bytes).

Not observed, and why: the risk named in SLD 7.4 is bytes that raw has already released (its Time Travel has expired) but that a replaced clone still references, which would then show as `RETAINED_FOR_CLONE_BYTES` on raw until the clone's own Time Travel expires. Raw's 1-day Time Travel still covers everything here, so that window has not opened. It opens roughly 24 hours after the run and lasts at most as long as the clone schema's retention. A re-read of `s09c_read_metrics.sql` at about 26 hours would show it for `RET1` and, by construction, never for `RET0`.

Design effect (SLD 7.4): setting a short retention on Silver schemas contains the replaced-clone risk to zero by construction (the replaced clone leaves nothing), at the cost of Time Travel on frozen inputs, which are rebuilt every run and never need it. The dominant storage cost of the freeze design is raw's own Time Travel, an ingestion decision, not a Silver one. Production volumes remain out of scope.
