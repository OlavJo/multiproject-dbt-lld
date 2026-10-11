# Spike snapshot

A read-only copy of [OlavJo/dbt-spikes-2026](https://github.com/OlavJo/dbt-spikes-2026) at commit [`e4800aa`](https://github.com/OlavJo/dbt-spikes-2026/tree/e4800aa) (2026-10-09: HLD v1.4 merged, spikes accepted), so this repository is self-contained.

**Do not edit anything under `reference/spikes/`.** It is the evidence the LLD cites. Paths inside it (for example "run `setup/08`" in `README.md`) are relative to this folder. New work goes in `docs/` and `prototype/` at the repository root; new evidence in the root `evidence/`.

| Path | Content |
|---|---|
| `README.md` | The spikes repository README: purpose, evidence convention, how a spike runs |
| `setup/` | Spike set-up scripts `00` to `10` (the "skeleton" the LLD cites as `setup/08`, and so on) |
| `spikes/` | One folder per spike, with its scripts and README |
| `dbt/` | The spike dbt projects, including the Silver skeleton `dbt/silver/` |
| `evidence/` | Spike evidence CSVs |
| `docs/spike-log.md` | Chronological log of spike runs, findings and decisions |
| `docs/hld/` | HLD v1.4 as accepted, with the v1.3 originals in `docs/hld/v1.3/` (the working copy of the HLD is the root `docs/hld/`) |
