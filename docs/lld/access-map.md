# Access map

A quick reference to the roles, what they hold, what they own and what they may do, **as built in the prototype** (Increment 1, 2026-10-12). The design and its reasons are in [`01-identity-and-access.md`](01-identity-and-access.md); this page shows the result. It is updated in every increment's pull request that changes a role, an ownership or a grant.

Ownership is drawn as a privilege (`OWNERSHIP`), as Snowflake treats it: thick arrows are `OWNERSHIP`, thin arrows are other privileges. `<unit>` stands for each Silver unit (`erp`, `crm`, `hr`, `core`), `<source>` for each raw source.

**Colours:** grey system role · blue functional role (people) · orange owner role · purple utility or access role · green service role (one per unit) · yellow database role.

## 1. Who holds which role

An arrow points from the holder to the role it holds, so privileges flow against the arrow. Every account role is also granted to `SYSADMIN`; only the top-level ones are drawn.

```mermaid
flowchart TB
  classDef sys fill:#eceff1,stroke:#607d8b,color:#263238
  classDef func fill:#e3f2fd,stroke:#1e88e5,color:#0d47a1
  classDef own fill:#fff3e0,stroke:#fb8c00,color:#e65100
  classDef util fill:#f3e5f5,stroke:#8e24aa,color:#4a148c
  classDef svc fill:#e8f5e9,stroke:#43a047,color:#1b5e20
  classDef dbr fill:#fffde7,stroke:#c0a000,color:#5d4b00

  STEWARDP(["Steward"]) --> OPERATOR["SILVER_OPERATOR"]:::func
  ANALYSTP(["Analyst"]) --> AALL["ANALYST_ALL"]:::func
  ANALYSTP --> AHR["ANALYST_HR"]:::func

  SYSADMIN["SYSADMIN<br/>holds every account role"]:::sys
  SYSADMIN --> PLATFORM["PLATFORM_INGEST"]:::own
  SYSADMIN --> STEWARD["SILVER_STEWARD"]:::own
  SYSADMIN --> PROV["SILVER_PROVISIONER"]:::util
  SYSADMIN --> SVC["SVC_SILVER_&lt;UNIT&gt;<br/>one per unit"]:::svc

  SVC --> BASE["SILVER_UNIT_BASE"]:::util
  SVC --> TASKR["TASK_RUNNER"]:::util
  SVC -->|granted by the platform| RAWR["raw.reader_&lt;source&gt;"]:::dbr
  SVC -->|its declared Silver upstreams| SR["silver.reader_&lt;unit&gt;"]:::dbr
  AALL --> SRA["silver.reader"]:::dbr
  SRA -->|non-sensitive units only| SR
  AHR -->|a sensitive unit, e.g. HR| SR
```

Examples from the demo: `SVC_SILVER_CORE` holds `silver.reader_erp` and `silver.reader_crm` (its declared upstreams), not `silver.reader_hr`. `silver.reader` holds the readers of ERP, CRM and Core; HR is sensitive, so only `ANALYST_HR` reaches `silver.reader_hr`.

## 2. Owners, provisioning and operation

```mermaid
flowchart LR
  classDef own fill:#fff3e0,stroke:#fb8c00,color:#e65100
  classDef func fill:#e3f2fd,stroke:#1e88e5,color:#0d47a1
  classDef obj fill:#ffffff,stroke:#9e9e9e,color:#212121

  PLATFORM["PLATFORM_INGEST"]:::own ==>|OWNERSHIP| RAW[("raw database, schemas, tables;<br/>raw.reader_&lt;source&gt;")]:::obj
  STEWARD["SILVER_STEWARD"]:::own ==>|OWNERSHIP| SILVER[("silver database;<br/>silver.ops schema")]:::obj
  STEWARD ==>|OWNERSHIP| AOPS[("analytics_ops.control:<br/>tables, log_event")]:::obj
  OPERATOR["SILVER_OPERATOR"]:::func -->|SELECT| AOPS
  OPERATOR -->|USAGE| PROCS[("silver.ops<br/>provisioning procedures")]:::obj
```

```mermaid
flowchart LR
  classDef util fill:#f3e5f5,stroke:#8e24aa,color:#4a148c
  classDef obj fill:#ffffff,stroke:#9e9e9e,color:#212121

  PROV["SILVER_PROVISIONER"]:::util
  PROV -->|CREATE ROLE| ACCT[("Account")]:::obj
  PROV ==>|OWNERSHIP| ROLESOBJ[("SVC_SILVER_&lt;UNIT&gt;, SILVER_UNIT_BASE,<br/>TASK_RUNNER, silver.reader,<br/>silver.reader_&lt;unit&gt;")]:::obj
  PROV ==>|OWNERSHIP| PROCS[("silver.ops<br/>provisioning procedures")]:::obj
  PROV -->|CREATE SCHEMA,<br/>CREATE DATABASE ROLE| SILVER[("silver database;<br/>silver.ops schema")]:::obj
  PROV -->|"SELECT config,<br/>lease DML, USAGE log_event"| AOPS[("analytics_ops.control")]:::obj
```

## 3. A unit and its readers

```mermaid
flowchart LR
  classDef util fill:#f3e5f5,stroke:#8e24aa,color:#4a148c
  classDef svc fill:#e8f5e9,stroke:#43a047,color:#1b5e20
  classDef dbr fill:#fffde7,stroke:#c0a000,color:#5d4b00
  classDef obj fill:#ffffff,stroke:#9e9e9e,color:#212121

  SVC["SVC_SILVER_&lt;UNIT&gt;"]:::svc
  BASE["SILVER_UNIT_BASE"]:::util
  TASKR["TASK_RUNNER"]:::util
  RAWR["raw.reader_&lt;source&gt;"]:::dbr
  SR["silver.reader_&lt;unit&gt;"]:::dbr

  UNITSCH[("silver.&lt;unit&gt;<br/>managed access")]:::obj
  SILVER[("silver database,<br/>silver.ops")]:::obj
  AOPS[("analytics_ops.control")]:::obj
  WH[("LLD_WH")]:::obj
  ACCT[("Account")]:::obj
  RAW[("raw.&lt;source&gt;<br/>schema and tables")]:::obj

  SVC ==>|OWNERSHIP| UNITSCH
  BASE -->|"USAGE, CREATE SCHEMA on silver;<br/>USAGE on silver.ops"| SILVER
  BASE -->|"SELECT units, unit_dependencies,<br/>publish_log; USAGE log_event"| AOPS
  BASE -->|USAGE| WH
  TASKR -->|EXECUTE TASK| ACCT
  RAWR -->|"USAGE, SELECT"| RAW
  SR -->|"USAGE (granted at each publication),<br/>SELECT on published objects"| UNITSCH
```

## 4. Matrix

| Role | Kind | Holds | `OWNERSHIP` of | Other privileges |
|---|---|---|---|---|
| `SYSADMIN` | System | Every account role below | `LLD_WH`, `LLD_LAB` | |
| `PLATFORM_INGEST` | Owner | | `raw` database, `raw.<source>` schemas and tables, `raw.reader_<source>` | `USAGE` on `LLD_WH` |
| `SILVER_STEWARD` | Owner | | `silver` database, `silver.ops`, `analytics_ops` and everything in `analytics_ops.control` (tables, `log_event`) | `USAGE` on `LLD_WH` |
| `SILVER_PROVISIONER` | Utility | | `SILVER_UNIT_BASE`, `TASK_RUNNER`, every `SVC_SILVER_<UNIT>`; `silver.reader`, every `silver.reader_<unit>`; the procedures in `silver.ops` | `CREATE ROLE` on the account; `USAGE`, `CREATE SCHEMA`, `CREATE DATABASE ROLE` on `silver`; `USAGE`, `CREATE PROCEDURE` on `silver.ops`; `SELECT` on `units`, `unit_dependencies`; `SELECT`, `INSERT`, `DELETE` on `unit_lease`; `USAGE` on `log_event`; `USAGE` on `LLD_WH` |
| `SILVER_UNIT_BASE` | Access | | | `USAGE`, `CREATE SCHEMA` on `silver`; `USAGE` on `silver.ops`; `USAGE` on `analytics_ops`, `analytics_ops.control`; `SELECT` on `units`, `unit_dependencies`, `publish_log`; `USAGE` on `log_event`; `USAGE` on `LLD_WH` |
| `TASK_RUNNER` | Access | | | `EXECUTE TASK` on the account (INC1.90) |
| `SVC_SILVER_<UNIT>` | Service | `SILVER_UNIT_BASE`, `TASK_RUNNER`; `raw.reader_<source>` (Source Entity units, from the platform); `silver.reader_<upstream>` for each declared Silver upstream | `silver.<unit>` (managed access); from Increment 2, `silver.<unit>__build` and its task | Through the roles it holds |
| `SILVER_OPERATOR` | Functional | | | `USAGE` on `onboard_unit`, `offboard_unit`, `grant_unit_reader`, `revoke_unit_reader`; `SELECT` on `units`, `unit_dependencies`, `publish_log`, `unit_lease`; `USAGE` on `LLD_WH` |
| `ANALYST_ALL` | Functional (consumer) | `silver.reader` | | `USAGE` on `LLD_WH` |
| `ANALYST_HR` | Functional (consumer) | `silver.reader_hr` | | `USAGE` on `LLD_WH` |
| `raw.reader_<source>` | Database role | | | `USAGE` on `raw.<source>`; `SELECT` on its tables, present and future |
| `silver.reader` | Database role | Every non-sensitive `silver.reader_<unit>` | | |
| `silver.reader_<unit>` | Database role | | | `USAGE` on `silver.<unit>`, granted at each publication (F3; INC1.42 stands in until Increment 2); `SELECT` on published objects (dbt `grants`, Increment 2) |

Every prototype role also has `USAGE` on `LLD_LAB.EVIDENCE` and its procedures, and `INSERT` on the evidence table (trial shortcut T6). Trial shortcut T1: the one trial user holds every role; in production people hold functional roles only.
