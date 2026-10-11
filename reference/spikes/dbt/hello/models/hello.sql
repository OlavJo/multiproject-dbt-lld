-- Records which dbt runtime and which Snowflake role actually built this model.
select
    '{{ dbt_version }}'   as dbt_version,
    current_role()        as run_role,
    current_warehouse()   as run_warehouse,
    sysdate()             as built_at_utc
