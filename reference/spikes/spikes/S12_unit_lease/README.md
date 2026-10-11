# S12: Unit lease, stale STARTED detection, DEPLOYED trigger

**Status:** **complete** (2026-10-05): all cases PASS, and the races are confirmed concurrent from query history.

## Question

SLD 12.4: two runs of one unit must never overlap, because both would replace the same build schema and one could swap the other's half-built schema into production. The lease is acquired by a single conditional `UPDATE` inside a transaction, and the run proceeds only if one row was updated. It expires after the unit's `max_runtime_minutes`, so a dead run cannot block the unit for ever.

To establish:

1. Acquire and release semantics, including that only the holder can release.
2. Expiry: a new run can take over a dead run's lease, and the dead run cannot then release the new holder's lease.
3. **Under concurrent attempts, exactly one run acquires the lease.**
4. Stale `STARTED` detection (SLD 12.6) and the "something new to build" gate including the `DEPLOYED` event (SLD 12.7).
5. Privilege boundaries: unit service roles use the lease only through procedures.

## Method

`s12_unit_lease.sql` creates a first cut of `ANALYTICS_OPS.CONTROL` (owned by `SILVER_STEWARD`, managed access): `units`, `unit_dependencies`, `publish_log`, `unit_lease`, the owner's-rights procedures `acquire_lease` and `release_lease`, and the views `unit_status`, `unit_stale` and `unit_has_new_input`.

| Part | Cases | What is exercised |
|---|---|---|
| A | S12.01 to S12.06 | Acquire, refuse, wrong-run release, holder release, re-acquire |
| B | S12.10 to S12.13 | Expiry (unit with `max_runtime_minutes = 0`), takeover, dead run cannot release |
| C | S12.20 to S12.22 | Service role cannot update the lease or write the log directly; consumer cannot call the procedures |
| D | S12.30 to S12.34 | **Five races of 20 concurrent contenders**, run as Snowflake Scripting asynchronous child jobs (`ASYNC` / `AWAIT ALL`). Each contender is the publish procedure's step 0: acquire, then record the outcome |
| E | S12.40 to S12.42 | Stale `STARTED` detection from the log |
| F | S12.50 to S12.54 | Gate condition 2: nothing new, `DEPLOYED`, published, upstream `PUBLISHED`; watermark derived from the log |

S12.31 records how far the contenders' attempts were spread in time, as evidence that they overlapped.

## Result

### Run 1 (2026-10-05, `evidence/S12_20261005.csv`): all 27 cases PASS

| Part | Cases | Observed |
|---|---|---|
| A | S12.01 to S12.06 | acquire `true`; second run `false`; wrong-run release `false`; holder still `...-r1`; holder release `true`; re-acquire `true` |
| B | S12.10 to S12.13 | dead run acquires; after expiry a new run takes over (`true`); the dead run's release is refused (`false`); holder is `...-d2` |
| C | S12.20 to S12.22 | `UPDATE` on the lease: `must have UPDATE granted`; insert into the log: not authorized; consumer: `Unknown user-defined function` |
| **D** | **S12.30 to S12.33** | **100 contenders, 100 distinct run ids; 0 races without exactly one winner; 0 races where the winner was not the holder**; attempts per race spread over at most 7.3 s |
| E | S12.40 to S12.42 | stale `true` for a dead run; `false` while running; `false` after a terminal event |
| F | S12.50 to S12.54 | gate `false`, then `true` after `DEPLOYED`, `false` after publishing, `true` after an upstream `PUBLISHED`; watermark derived from the log |

**Strength of the concurrency evidence.** Each contender records its timestamp after its acquire attempt returns, so the 7.3 s spread (S12.31) alone would also arise from serial execution. The direct evidence is S12.34.

### S12.34: concurrency from query history (2026-10-05, `s12_concurrency_check.sql`, run manually)

| Measure | Expected | Observed |
|---|---|---|
| Lease `UPDATE` statements in query history | 105 (100 contenders + 5 acquires in Parts A and B) | **105** |
| Maximum number in progress at the same moment | more than 1 | **20** |

All 20 contenders of at least one race had their lease `UPDATE` in progress simultaneously (executing or waiting on the lock), and every race still had exactly one winner. Statements inside the owner's-rights procedure are visible in query history to `ACCOUNTADMIN`.

## Interpretation

1. **The lease works as SLD 12.4 specifies**: one conditional `UPDATE` in a transaction, success iff one row updated, owner's-rights procedures so unit service roles have no privileges on the table.
2. **Release must be conditional on the holder's run id** (S12.03, S12.12). Without that, a run that resumes after its lease expired could release the lease of the run that took over, letting a third run start while the second is still building.
3. **Asynchronous child jobs work as a concurrency harness** in Snowflake Scripting: `ASYNC (CALL ...)` in a loop plus `AWAIT ALL`, and `CALL ... INTO :var` to capture a procedure's result.
4. **The append-only log is enough to derive status, staleness and the gate** (S12.40 to S12.54), as SLD 12.1 intends.

## Effect on the design

- **SLD 12.4 and 12.6 to 12.7 confirmed as designed**, including under 20-way concurrent acquisition (S12.32 with S12.34).
- LLD detail: `release_lease` takes the run id and releases only if it matches; the publish procedure releases on every exit path, and a release that returns `false` is logged as an anomaly (the run outlived its lease).
- LLD detail: the lease procedures are owner's rights and owned by the steward role; unit service roles get `USAGE` on the procedures and, at most, `SELECT` on the lease table.
