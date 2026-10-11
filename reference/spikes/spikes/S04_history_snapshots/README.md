# S4: snapshots and CDC history under clone-build-discard-retry

**Status:** **complete** (2026-10-07, `evidence/S4_20261007.csv`): all 35 cases PASS on the first run.

## Question

SLD 6.7 and 14 (S4): history is a published guarantee (G8). For a CDC source, a history model gives one row per key per version with `valid_from` and `valid_to` from the source's own ordering; for a source without change capture, a snapshot records change as observed between batches, and because builds read frozen inputs the snapshot's validity timestamps must be the **unit watermark**, not the build's clock, so that a retried build stamps the same time. Every build starts as a clone of the last good state (retries are idempotent, SLD 10.7 rule 4).

1. Is the CDC history correct from the source ordering column, including **a late change** (lower ordering value, later arrival), **a redelivered change** and **a delete**?
2. Does a snapshot stamped from the watermark (not the clock) come out **identical** when a build is discarded and retried at the same watermark?
3. Do both survive the publish cycle (clone, build, swap, repeat)?

## What is built

`dbt/silver` (unit `s4`, target `prod_s4`, selector `unit_s4`):

| Piece | Where |
|---|---|
| CDC history: incremental merge on `(order_id, source_seq)`; each run recomputes the validity of every key that received a change, reading the key's existing versions from the table; a delete is a tombstone version; permanent | `models/s4/s4_orders_history.sql` |
| CDC current state: latest change per key by the ordering column, without deletes; transient | `models/s4/s4_orders_current.sql` |
| Snapshot of a full-load table (`check` strategy on all columns, hard deletes invalidated); permanent | `snapshots/s4/s4_customers_snapshot.sql` |
| `snapshot_get_time` override: validity stamps read the watermark the freeze recorded in `<unit>__build._freeze` | `macros/snapshot_time.sql`, `macros/freeze_sources.sql` |
| History tests on the output (SLD 8): `history_contiguous` (no gaps or overlaps), `one_open_version`, `current_matches_history` | `macros/history_tests.sql`, `models/s4/schema.yml` |

## Method (`s04_history_snapshots.sql`, about 12 minutes)

| Part | What |
|---|---|
| A | Four batches through `publish_unit('silver.s4')`. B1 inserts and an update; B2 an update, an insert and a delete, and customer changes; B3 a redelivered change and a late change; B4 a customer tier change. After each publication, versions per key, contiguity, current state, snapshot rows and stamps against the published watermark |
| B | Clone-build-discard-retry by direct calls: batch 4 lands; clone, freeze, a build that fails **after** the snapshot ran (an injected output test fails); fingerprint the snapshot and history; discard, re-clone, re-freeze at the same watermark, build; fingerprints must be identical |
| C | Negative control: the history is tampered with in a build schema, and the history test must fail |
| D | Publication of B4 through the procedure and the final state |

## Result (`evidence/S4_20261007.csv`)

| Part | Observed |
|---|---|
| **A, B1** | History: order 1 `10:01-10:03, 30: 10:03-open`; current state 2 rows; snapshot 3 rows, all open, **validity equal to the published watermark, not the clock** (S4.A1.05) |
| **A, B2** | Order 1 has three versions, each closing exactly when the next opens; **order 2's insert is closed by the delete tombstone (`D`, flagged, open)**; current state `1,3` (the deleted order excluded); snapshot 5 rows (customer 1 twice, customer 2 closed by the hard delete, 3, 4); customer 1's old version closes exactly when the new opens, **at the published watermark**; the deleted customer is closed at that same watermark |
| **A, B3** | **The late change (seq 40, committed 10:04, arriving after seq 50) slots in by ordering value and re-closes its neighbour** (`30: 10:03-10:04`, `40: 10:04-10:05`, `50: 10:05-open`); **the redelivered change is stored once**; the late change does not become the current state (`SHIPPED`); the snapshot is unchanged by an orders-only batch |
| **B, retry** | A build that fails **after the snapshot ran** (an output test failed with `PASS=17 ERROR=1 SKIP=0`: the independent snapshot node still ran, S4.B1.03: 2 versions of customer 3 in the build schema) is discarded; the re-clone, re-freeze at the same watermark and rebuild give a **snapshot and a history with identical fingerprints** (S4.B2.03, B2.04), and customer 3's new version is stamped with the batch-4 watermark (S4.B2.05) |
| **C, negative control** | With the history tampered with (a version closing a minute late), `history_contiguous` fails: `in test history_contiguous_... Got 1 result` |
| **D, B4** | Publication through the procedure: snapshot 6 rows (customer 3 twice), the new version stamped with the published watermark, history unchanged (7), **history and snapshot are permanent tables, the current state transient** |

## Conclusions for the design (SLD 6.7, 8, 10.7 rule 4, 13.4)

1. **A CDC history model built as an incremental merge on `(key, source ordering value)`, which recomputes the validity of every key that received a change from the key's existing versions plus the new rows, is correct** for inserts, updates, deletes (tombstones), redelivered changes and late changes, and survives the publish cycle. It does not depend on raw's change log beyond the batch being processed.
2. **Stamping snapshots with the unit watermark gives idempotent retries**: a discarded and retried build produces an identical snapshot. The mechanism is small: the freeze records the watermark in `<unit>__build._freeze`; a `snowflake__snapshot_get_time` override reads it (outside a publication the clock is used).
3. **Snapshots capture the state of the frozen input at each watermark, not each change in between**: if a unit publishes less often than batches land, changes between two publications are seen only as their net effect. This is inherent for sources without change capture (SLD 6.7 already says a snapshot records change as observed between batches).
4. **The history tests must run on the output** (`history_contiguous`, `one_open_version`, `current_matches_history`); the negative control shows they fail on a broken history.
5. **Permanent tables must not be fully refreshed** (SLD 13.4: history cannot be rebuilt beyond raw's retention). The LLD should set `full_refresh: false` on history models and snapshots; not tested here.
6. **Not tested:** a key that is inserted again after its delete; a late change older than a tombstone; large volumes (the recompute is per affected key, so cost scales with the number of changed keys and their versions); a change of the history model's columns (`on_schema_change: fail` is set).
