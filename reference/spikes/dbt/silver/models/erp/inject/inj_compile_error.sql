-- Failure injection for spike S3: enabled only with --vars '{inject_failure: compile_error}'.
-- A jinja error at parse and compile time, before anything runs in the warehouse.
{{ config(enabled=(var('inject_failure', '') == 'compile_error')) }}
select {% if var('inject_failure', '') == 'compile_error' %}{{ s3_undefined_macro() }}{% endif %} 1 as x
