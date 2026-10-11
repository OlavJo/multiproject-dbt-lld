{#- Generic tests for history models (SLD 8: history validity is tested on the output). -#}

{#- No gaps or overlaps per key: each version closes exactly when the next one opens, only the
    last version of a key is open, and no version closes before it opens. -#}
{% test history_contiguous(model, key, valid_from, valid_to, seq) %}
with ordered as (
    select {{ key }} as k, {{ valid_from }} as f, {{ valid_to }} as t,
           lead({{ valid_from }}) over (partition by {{ key }} order by {{ seq }}) as next_f,
           lead({{ seq }}) over (partition by {{ key }} order by {{ seq }}) as next_seq
    from {{ model }}
)
select * from ordered
where (t is not null and (t <> next_f or t < f))
   or (t is null and next_seq is not null)
   or (t is not null and next_seq is null)
{% endtest %}

{#- Exactly one open version per key -#}
{% test one_open_version(model, key, valid_to) %}
select {{ key }} as k, count_if({{ valid_to }} is null) as open_versions
from {{ model }}
group by {{ key }}
having count_if({{ valid_to }} is null) <> 1
{% endtest %}

{#- The current-state model equals the open, non-deleted versions of the history model -#}
{% test current_matches_history(model, history, key, columns) %}
with cur as (select {{ columns | join(', ') }} from {{ model }}),
     hist as (select {{ columns | join(', ') }} from {{ history }} where valid_to is null and not is_deleted)
select 'only_in_current' as side, * from (select * from cur except select * from hist)
union all
select 'only_in_history' as side, * from (select * from hist except select * from cur)
{% endtest %}

{#- The model has the same rows as another relation on the given columns (spike S10: two reads
    of upstream data in one build must agree) -#}
{% test same_rows(model, other, columns) %}
select 'only_in_model' as side, * from (select {{ columns | join(', ') }} from {{ model }} except select {{ columns | join(', ') }} from {{ other }})
union all
select 'only_in_other' as side, * from (select {{ columns | join(', ') }} from {{ other }} except select {{ columns | join(', ') }} from {{ model }})
{% endtest %}
