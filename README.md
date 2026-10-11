# multiproject-dbt-lld

Low Level Design and prototype for multi-project dbt on Snowflake.

This repository is self-contained. It continues the work of the spikes repository, [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026), which is frozen as the reference milestone at commit `e4800aa` (HLD v1.4 merged, spikes accepted). Everything from it that the LLD cites is copied, read-only, into `reference/spikes/`.

## Layout

```
docs/
  hld/                  HLD v1.4, the working copy: the LLD may lead to a v1.5 here
  lld/                  Low Level Design: component map, decision register, one document per component
  next-session.md       Handover: where things stand and the next steps
prototype/              The prototype, built in increments alongside the LLD (see prototype/README.md)
evidence/               Prototype evidence, one CSV per demo run (INC<n>_<yyyymmdd>.csv)
reference/spikes/       Read-only snapshot of the spikes repository at e4800aa (see SNAPSHOT.md)
```

## References to the spikes

The LLD cites the spike work by its original paths, for example `setup/08`, `spikes/S12_unit_lease/`, `dbt/silver/`, the spike log, or spike case `S10.C3`. These paths are relative to `reference/spikes/`: `setup/08` is `reference/spikes/setup/08_publish_procedure.sql`, the spike log is `reference/spikes/docs/spike-log.md`, spike evidence is in `reference/spikes/evidence/`.

## Evidence convention

As in the spikes: observations go into `SPIKE_LAB.EVIDENCE.OBSERVATION` through the caller's-rights procedures `PROBE` (one SQL statement as the calling role; its first value is compared with an expected `ILIKE` pattern, `!` negates) and `RECORD` (for values read from `SHOW` output). Both, and the table, are created by `prototype/00_lab_foundation.sql`. `EXPECTED` records what the design predicts; a `FAIL` is a finding, not a script error. After a demo, export its rows (query at the end of each demo) to `evidence/INC<n>_<yyyymmdd>.csv` and commit. The columns are described in `reference/spikes/README.md`, "Evidence convention".
