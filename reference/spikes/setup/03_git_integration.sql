-- =============================================================================
-- Phase 0 / Step 03: Git integration (private repository)
-- Connects Snowflake to https://github.com/OlavJo/dbt-spikes-2026 so dbt project
-- objects can be created from it, as CI would in production.
--
-- BEFORE RUNNING: create a GitHub fine-grained personal access token
--   GitHub > Settings > Developer settings > Personal access tokens >
--   Fine-grained tokens > Generate new token
--     Repository access: Only select repositories > dbt-spikes-2026
--     Permissions:       Repository permissions > Contents: Read-only
--     Expiration:        the length of the spikes (e.g. 60 days)
--
-- Paste the token into the CREATE SECRET below, run the script, then delete the
-- token from the worksheet. NEVER commit the token. Snowflake stores it
-- encrypted in the secret; nothing else needs it.
-- =============================================================================

use secondary roles none;

-- Secret: owned by the steward, who owns the Git repository object ------------
use role silver_steward;
use warehouse spike_wh;

-- IF NOT EXISTS: rerunning this script must never overwrite the token with the
-- placeholder. To rotate or re-set the token, run instead:
--   alter secret spike_lab.git.github_pat set password = '<token>';
create secret if not exists spike_lab.git.github_pat
  type     = password
  username = 'OlavJo'
  password = '<paste token here on first run only, then delete it from the worksheet>';

-- API integration: account-level, created by ACCOUNTADMIN -----------------------
use role accountadmin;

create or replace api integration spike_git_api
  api_provider                   = git_https_api
  api_allowed_prefixes           = ('https://github.com/OlavJo/dbt-spikes-2026.git')  -- must include .git: prefixes match whole path segments
  allowed_authentication_secrets = (spike_lab.git.github_pat)
  enabled                        = true;

grant usage on integration spike_git_api to role silver_steward;

-- Git repository object -----------------------------------------------------------
use role silver_steward;

create or replace git repository spike_lab.git.spikes_repo
  api_integration = spike_git_api
  git_credentials = spike_lab.git.github_pat
  origin          = 'https://github.com/OlavJo/dbt-spikes-2026.git';

-- Check: fetch and list --------------------------------------------------------
alter git repository spike_lab.git.spikes_repo fetch;
show git branches in spike_lab.git.spikes_repo;
ls @spike_lab.git.spikes_repo/branches/main/dbt/hello/;

set run_id = (select uuid_string());
call spike_lab.evidence.probe($run_id, 'P0', 'P0.13',
  'Private Git repository readable from Snowflake via PAT secret (hello project present)',
  $$ls @spike_lab.git.spikes_repo/branches/main/dbt/hello/dbt_project.yml$$,
  '%dbt_project.yml%');

-- Evidence: the secret's existence and owner are recorded, never its value
show secrets like 'GITHUB_PAT' in schema spike_lab.git;
insert into spike_lab.evidence.observation
  select $run_id, 'P0', 'P0.14',
         'Secret exists and is owned by the steward role',
         'show secrets like ''GITHUB_PAT'' in schema spike_lab.git', 'GITHUB_PAT owned by SILVER_STEWARD',
         "name" || ' owned by ' || "owner",
         iff("name" || ' owned by ' || "owner" = 'GITHUB_PAT owned by SILVER_STEWARD', 'PASS', 'FAIL'),
         current_role(), current_secondary_roles(), sysdate(), current_version(), null
  from table(result_scan(last_query_id()));

select case_id, outcome, observed
from spike_lab.evidence.observation
where run_id = $run_id
order by case_id;
