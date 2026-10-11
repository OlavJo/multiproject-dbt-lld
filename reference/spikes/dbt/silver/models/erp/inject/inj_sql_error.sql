-- Failure injection for spike S3: enabled only with --vars '{inject_failure: sql_error}'.
-- A model whose SQL fails at execution (a warehouse error), after the build starts.
{{ config(enabled=(var('inject_failure', '') == 'sql_error'), materialized='table') }}
select 1 / 0 as x
