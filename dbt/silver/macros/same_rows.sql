{#- Generic test: the model and compare_to hold the same rows (spike S10's consistency detector,
    SLD 10.9). Fails with the rows that differ either way. -#}
{% test same_rows(model, compare_to) %}
(select * from {{ model }} minus select * from {{ compare_to }})
union all
(select * from {{ compare_to }} minus select * from {{ model }})
{% endtest %}
