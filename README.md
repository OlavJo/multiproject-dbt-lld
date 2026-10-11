# multiproject-dbt-lld

Low Level Design and prototype for multi-project dbt on Snowflake.

This repository continues the work of the spikes repository, [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026), which is **frozen** as the reference milestone at commit [`e4800aa`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa) (HLD v1.4 merged, spikes accepted). Nothing is changed there any more; this repository refers to it.

## Layout

```
docs/
  hld/                  HLD v1.4 as accepted after the spikes (baseline copy; CHANGES-v1.4.md lists the changes from v1.3)
  lld/                  Low Level Design: component map, decision register, one document per component
  next-session.md       Handover: where things stand and the next steps
prototype/              The prototype, built in increments alongside the LLD (see prototype/README.md)
evidence/               Exported evidence rows from prototype demos, one CSV per increment run
```

## References to the spikes repository

The LLD cites the spike work by path, for example `setup/08`, `spikes/S12_unit_lease/`, `docs/spike-log.md` or a spike evidence CSV. Unless a path exists in this repository, it refers to the spikes repository at `e4800aa`:

- Spike scripts: [`setup/`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa/setup), [`spikes/`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa/spikes)
- Spike skeleton dbt project: [`dbt/silver/`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa/dbt/silver)
- Spike evidence: [`evidence/`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa/evidence)
- Spike log: [`docs/spike-log.md`](https://github.com/OlavJo/dbt-spikes-2026/blob/e4800aa/docs/spike-log.md)
- HLD v1.3 originals: [`docs/hld/v1.3/`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa/docs/hld/v1.3)

The `evidence/` folder in this repository holds prototype evidence only (`INC<n>_<yyyymmdd>.csv`).

## Evidence convention

As in the spikes: observations go into `SPIKE_LAB.EVIDENCE.OBSERVATION` through the caller's-rights procedures `PROBE` (one SQL statement, first value compared with an expected `ILIKE` pattern) and `RECORD` (for values read from `SHOW` output). The table and `PROBE` were created by the spike set-up (`setup/00`, `setup/01` in the spikes repository) and are kept by the Increment 0 teardown; `RECORD` is created by `prototype/01_identity/i1_10_foundation.sql`. A `FAIL` is a finding, not a script error. After a demo, export its rows (query at the end of each demo) to `evidence/INC<n>_<yyyymmdd>.csv` and commit.
