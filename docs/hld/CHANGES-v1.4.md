# Changes from v1.3 to v1.4

Both documents (Overview and Silver Layer Design, SLD) move from v1.3 to v1.4 after the spikes. The v1.3 originals are in `v1.3/`. Evidence for each item is in `docs/spike-log.md`, `spikes/<spike>/README.md` and `evidence/`.

## Corrections (the v1.3 text was wrong or incomplete)

| # | Change | Spike | Where |
|---|---|---|---|
| 1 | `EXECUTE DBT PROJECT` **raises** on a dbt failure; it does not return `FALSE`. Result columns are `SUCCESS`, `EXCEPTION`, `STDOUT` (no `OUTPUT_ARCHIVE_URL`); `EXCEPTION` is the string `'None'` on success. The procedure uses an exception handler and classifies failures from the raised text | S3, P0 | SLD 3.1, 10.4, 10.7, 10.8 |
| 2 | Schema-level `USAGE` moves with the schema object under `SWAP WITH`. The swap step is grant on build, swap, revoke on the new build schema | S2 | SLD 10.4, 10.7 |
| 3 | A schema clone does not inherit managed access, and `ENABLE MANAGED ACCESS` needs `MANAGE GRANTS`. Use `CLONE ... WITH MANAGED ACCESS` | S2 | SLD 10.4, 10.7 |
| 4 | Semantic views bind bare names to the session schema at creation, so they reference **published** names; new columns lag one publication | S1 | SLD 10.5, 10.7 |
| 5 | Classification: `PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT` tags replace the post-hook (the weaker mode stops at views). Declassification is a reserved tag value with a value-aware masking policy, not `UNSET`. Each tag needs a policy per data type | S9, S9b, S9d, S9e, S9f | SLD 6.3; Overview 7.3, 10 |
| 6 | Canonical state reaches CI through `IMPORTS = ('<path>/target/' AS 'state')` and `--state ./imports/state`; a stage path to `--state` is not read | S6 | SLD 3.2 |
| 7 | Deployment is `ALTER DBT PROJECT ... ADD VERSION`; `CREATE OR REPLACE` drops grants and orphans canonical state | S8c, S8g | SLD 3.2, 10.7 |
| 8 | Each unit runs as its own service role (a caller's-rights procedure creates schemas as the caller's primary role) | S8 | SLD 3.1, 10.12 |
| 9 | Unit selectors must be closed under the unit (folder path only; no `children: true`) | S10 | SLD 10.3 |
| 10 | Project macros are unavailable when a source's `schema:` is rendered; redirection lives in `source()` | offline, S6 | SLD 6.3 |
| 11 | Runtime: dbt Core 1.12.3 (dbt-snowflake 1.12.0) replaces 1.11.11; `latest_version_pointer` is available | P0 | Overview 2, 8.2, 10; SLD 3.3 |

## Resolved open issues

| Change | Spike | Where |
|---|---|---|
| Consistent reads across units: the problem reproduces (38 vs 40 rows); upstream schema clones at the gate fix it. Guarantee is per upstream. Privilege model left open | S10 | SLD 10.9; Overview 9.1 |
| S1 contingency (in-place frozen inputs) not needed | S1 | SLD 10.6 |
| Frozen-input storage: no storage of their own within raw's Time Travel; short schema retention removes the residual risk | S9c | SLD 7.4 |
| CDC history and snapshot semantics confirmed; `full_refresh: false` on permanent tables | S4 | SLD 6.3, 6.7 |
| Unit lease confirmed under 20-way concurrency | S12 | SLD 12.4 |
| Dev and CI targets, `state:modified.body+ --defer` | S6 | SLD 3.2, 10.11 |

## Additions

- SLD 3.1 scripting conventions and account settings (`DEFAULT_SECONDARY_ROLES`, `TIMEZONE`).
- SLD 10.11 (development and CI targets) and 10.12 (run roles).
- SLD 14 now records each spike's result; SLD 15 gains three rejected alternatives; SLD 16 lists the open items the spikes produced.
- Overview Appendix A (validation status).

## Not validated

S5 (clone time at production volume), S7 (dynamic tables), S11 (object identity options) and S13 (dbt Fusion) were not run. They were agreed as not deal breakers. S5 is the one to run early on real volumes. Also untested: file removal and dbt-version change through `ADD VERSION`, and publication windows.
