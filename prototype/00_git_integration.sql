-- =============================================================================
-- Prototype / Increment 0: Git integration for this repository
--
-- Connects Snowflake to https://github.com/OlavJo/multiproject-dbt-lld, kept
-- apart from the spike Git objects (SPIKE_LAB.GIT, SPIKE_GIT_API):
--   schema           LLD_LAB.GIT (owned by SYSADMIN)
--   secret           LLD_LAB.GIT.GITHUB_PAT
--   API integration  LLD_GIT_API, allowing this repository only
--   Git repository   LLD_LAB.GIT.LLD_REPO (used by Increment 2 for dbt project
--                    objects; a Snowsight Git Workspace uses the integration
--                    and secret directly)
--
-- BEFORE RUNNING: create a GitHub fine-grained personal access token
--   GitHub > Settings > Developer settings > Personal access tokens >
--   Fine-grained tokens > Generate new token
--     Repository access: Only select repositories > multiproject-dbt-lld
--     Permissions:       Repository permissions > Contents: Read and write
--                        (read and write lets the Snowsight Workspace commit
--                        and push; Read-only is enough for dbt project objects)
--     Expiration:        to the end of the trial (about 2026-11-04) or longer
--
-- Paste the token into the CREATE SECRET below, run the script, then delete the
-- token from the worksheet. NEVER commit the token.
--
-- Trial shortcut T4: a personal access token; production per CD-3.
-- Requires: 00_lab_foundation.sql (LLD_LAB, LLD_WH, PROBE, RECORD).
-- Run as: SYSADMIN and ACCOUNTADMIN (switches itself). Idempotent: rerunning
-- never overwrites the token. To rotate it:
--   alter secret lld_lab.git.github_pat set password = '<token>';
-- =============================================================================

use secondary roles none;

use role sysadmin;
use warehouse lld_wh;
create schema   if not exists lld_lab.git;

create secret if not exists lld_lab.git.github_pat
  type     = password
  username = 'OlavJo'
  password = '<paste token here on first run only, then delete it from the worksheet>';

use role accountadmin;
create api integration if not exists lld_git_api
  api_provider                   = git_https_api
  api_allowed_prefixes           = ('https://github.com/OlavJo/multiproject-dbt-lld.git')  -- must include .git
  allowed_authentication_secrets = (lld_lab.git.github_pat)
  enabled                        = true
  comment                        = 'LLD prototype: this repository only';
grant usage on integration lld_git_api to role sysadmin;

use role sysadmin;
create git repository if not exists lld_lab.git.lld_repo
  api_integration = lld_git_api
  git_credentials = lld_lab.git.github_pat
  origin          = 'https://github.com/OlavJo/multiproject-dbt-lld.git';

-- Check ------------------------------------------------------------------------------
alter git repository lld_lab.git.lld_repo fetch;
show git branches in lld_lab.git.lld_repo;

set run_id = (select uuid_string());
call lld_lab.evidence.probe($run_id, 'INC0', 'INC0.20',
  'This repository is readable from Snowflake through LLD_GIT_API and the PAT secret',
  $$ls @lld_lab.git.lld_repo/branches/main/README.md$$, '%README.md%');

show secrets like 'GITHUB_PAT' in schema lld_lab.git;
set obs = (select nvl(max("owner"), '<none>') from table(result_scan(last_query_id())));
call lld_lab.evidence.record($run_id, 'INC0', 'INC0.21', 'Secret exists and is owned by SYSADMIN (value never recorded)',
  'show secrets like ''GITHUB_PAT'' in schema lld_lab.git', 'SYSADMIN', $obs);

select case_id, outcome, observed
from lld_lab.evidence.observation
where run_id = $run_id
order by case_id;
