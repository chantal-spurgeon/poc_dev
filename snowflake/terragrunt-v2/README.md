**This is terragrunt-v2.** It is a cleaned-up copy of `../terragrunt`, which is kept unchanged for reference. The units here point at this folder (`snowflake/terragrunt-v2`), not the original. Changes so far are listed in the "Terragrunt folder review" section of the pinned review doc: private key kept out of generated files, corrected state block, stray `terraform.tfvars` removed, `.gitignore` added.

**Snowflake Terragrunt Deployment**

**Make sure Terraform and Terragrunt are installed.** This folder contains `.terraform-version` (1.16.7) and `.terragrunt-version` (1.2.1); `tfenv` and `tgenv` pick those up automatically once the versions are installed. Check `tfenv list-remote` and `tgenv list-remote` for newer stable releases before changing them.

   `brew tap hashicorp/tap`

   `brew install hashicorp/tap/terraform`
 
   `git clone https://github.com/tfutils/tfenv.git ~/.tfenv`
 
   `echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bash_profile`
 
   `echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.profile`
  
   `ln -s ~/.tfenv/bin/* /usr/local/bin`
  
   `. ~/.bash_profile`
 
   `tfenv list-remote`
 
   `tfenv install 1.16.7`
 
   `tfenv use 1.16.7`
 
   `tfenv list`

   `git clone https://github.com/cunymatthieu/tgenv.git ~/.tgenv`
   
   `echo 'export PATH="$HOME/.tgenv/bin:$PATH"' >> ~/.bash_profile`
   
   `echo 'export PATH="$HOME/.tgenv/bin:$PATH"' >> ~/.profile`
   
   `ln -s ~/.tgenv/bin/* /usr/local/bin`
   
   `. ~/.bash_profile`
   
   `tgenv list-remote`
   
   `tgenv install 1.2.1`
   
   `tgenv list`
   
   `tgenv use 1.2.1` 

 
****************

**RSA Keys for Snowflake (create key as named, and store in ~/.ssh/):**

Encrypted - will prompt for passphrase

`openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out snowflake_key.p8`

Unencrypted

`openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt`

`openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key.pub`

In Snowflake as ACCOUNTADMIN:

`ALTER USER your_snowflake_username SET RSA_PUBLIC_KEY='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...';`


****************

**Update your .bash_profile:**

`# Snowflake Authentication Details`

`export TF_VAR_snowflake_user="JOHN_DOE"`

`# The Snowflake provider reads these two directly. They are not written to any file.`

`# Automatically reads your secure local .p8 private key file`

`export SNOWFLAKE_PRIVATE_KEY=$(cat ~/.ssh/snowflake_key.p8)`

`# The decryption passphrase for your private key file (only if the key is encrypted)`

`export SNOWFLAKE_PRIVATE_KEY_PASSPHRASE="YourSecureKeyPassphraseHere"`

(The older `TF_VAR_snowflake_private_key` and `TF_VAR_snowflake_private_key_passphrase` are no longer used.)



****************

Run each unit from its own folder (`environment/snowflake_account_name/<unit>`), in this order: databases, integrations, security, warehouses, users, rbac, then monitoring and ai_cost_mgmt.

**Plan and run**

`terragrunt init`

`terragrunt plan`

`terragrunt apply`

To run every unit in dependency order from `environment/snowflake_account_name`, use `terragrunt run --all plan` (or `apply`). Older Terragrunt versions called this `run-all`. Units list their `dependencies`, so users waits for security and warehouses, and rbac waits for databases, integrations, users and warehouses.

To import resources (example; the key is the one in the unit's `inputs`, here `db_stray_kids8`):

`terragrunt import 'snowflake_database.managed_dbs["db_stray_kids8"]' 'DB_STRAY_KIDS8'`

**State.** No bucket is assigned yet, so each unit keeps its state as a local file inside its `.terragrunt-cache/` folder. Do not delete `.terragrunt-cache/` while resources exist: the state goes with it. To assign a bucket, enable the `remote_state` block in `root.hcl` (instructions are in the comments there).

****************

**What differs from `../terragrunt`**

| Area | terragrunt (original) | terragrunt-v2 |
| --- | --- | --- |
| Private key | Written into a generated `provider.tf` in each unit's cache | Read by the provider from `SNOWFLAKE_PRIVATE_KEY` / `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` |
| State block | Commented out, with a key that would not have worked | Commented out, key corrected, notes on locking |
| `terraform.tfvars` | Present; overrode the inputs | Removed |
| Sign-in role | `ACCOUNTADMIN` for every unit | Per unit, from `unit_roles` in `account.hcl` |
| Databases and schemas | Could be dropped by editing or renaming an input key | `prevent_destroy` (see below) |
| `SECURITY_ADMIN_CUSTOM8` | Inherited `SECURITYADMIN` (so SYSADMIN did too) | Holds the `SNOWFLAKE.SECURITY_VIEWER` database role only |
| Users | `default_warehouse` and `network_policy` were ignored; people could not use `rsa_public_key` | All three are applied |
| Secondary roles | `["\"ALL\""]` always resolved to `NONE` | `["ALL"]` |
| Variables | `map(any)`, so every role listed every key | Typed objects with defaults; list only what you set |
| `ignored_privileges` | Dropped silently | Warning on every plan, plus `terragrunt output ignored_privileges` |
| Unused variables | About six | Removed |

**Things to know**

- *Roles per unit.* Your Snowflake user needs each role in `unit_roles` granted. If a unit fails with "insufficient privileges", that unit's role is the first thing to check. `integrations` stays on `ACCOUNTADMIN` because `CREATE INTEGRATION` needs it; the better fix is a custom role holding only that privilege.
- *Retiring a database or schema.* `prevent_destroy` makes Terraform stop with an error instead of dropping one. To remove it from Terraform without dropping it, run `terragrunt state rm 'snowflake_database.managed_dbs["<key>"]'` and then delete the entry. To actually drop it, drop it in Snowflake yourself, then remove the entry and the state.
- *Ignored privileges.* `OWNERSHIP` on all/future object grants (your task ownership lines) and `MODIFY` on schemas are accepted but not applied. The plan warns about them. Decide whether to implement them or delete the lines.
- *Secondary roles on existing users.* The user resources have `ignore_changes` on `default_secondary_roles_option`, so fixing the value above affects only users created after the fix. Remove that `lifecycle` block if you want existing users updated (it may have been added to hide a provider diff, so check the first plan).
- *Typos in typed inputs.* Terraform drops attribute names a type does not list instead of failing, so a misspelled setting is ignored. If a setting has no effect, compare its spelling with `variables.tf`.
- *Not run.* None of this has been through `terragrunt validate` or `plan` yet. Expect to fix small things on the first run, starting with `terragrunt plan` in `databases`.

****************

**Monitoring unit (tables, views, procedures, tasks)**

`environment/snowflake_account_name/monitoring` creates the standard monitoring set in `ADMIN_DB.FINOPS`:

| Object | Kind | What it does |
| --- | --- | --- |
| `EGRESS_BY_ROLE_MONTHLY` | table | Estimated egress cost per role per month |
| `REFRESH_EGRESS_BY_ROLE_MONTHLY` | procedure | Recomputes this and last month (safe to re-run) |
| `REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK` | task | Calls the procedure daily at 6:00 AM Central |
| `V_EGRESS_REPORT` | view | The table with currency formatting |
| `POOL_STATE_LOG` | table | `SHOW COMPUTE POOLS` snapshots |
| `CAPTURE_POOL_STATE` | task | Takes a snapshot every 10 minutes, keeps 90 days |
| `UTIL_HOURLY`, `ERRORS_HOURLY`, `SERVICE_EVENTS_HOURLY` | tables | Hourly CPU/memory percentiles, error-like log lines and service events per pool and service |
| `ROLLUP_POOL_TELEMETRY` | task | At :05 each hour, summarises the last completed hour of the event table into the three tables above, and trims all history tables to 90 days |
| `SERVICE_STATE_LOG` | table | `SHOW SERVICES IN ACCOUNT` snapshots |
| `CAPTURE_SERVICE_STATE` | task | Takes a snapshot every 10 minutes, keeps 90 days |
| `POOL_CHANGE_LOG` | table | Written by hand before and after a pool setting change (rollback aid) |
| `V_POOL_DAILY`, `V_POOL_CREDITS_DAILY` | views | Suspends/resumes/time at max nodes, and credits per day |
| `V_HEADROOM_7D` | view | Peak CPU/memory per service over 7 days |
| `V_DAILY_SCORECARD` | view | Credits, suspends/resumes, time at max nodes, errors and restart-like events per pool per day |
| `V_POOL_KEEPERS_NOW` | view | Services currently keeping each pool awake |
| `V_SERVICE_RUNNING_HOURS_DAILY`, `V_SERVICE_PCT_OF_DAY`, `V_DAILY_KEEPERS` | views | How long each service ran per day, as hours and as a share of the day |
| `V_IDLE_BUT_RUNNING_24H` | view | Services that were RUNNING while their CPU stayed near zero |
| `POOL_SUSPEND_LOG`, `SUSPEND_POOL_IF_IDLE` | table, task | Optional: suspends one pool on weekday evenings if idle. Not created unless `idle_suspend_pool` is set |
| `NOTEBOOK_INVENTORY_LOG`, `NOTEBOOK_DESCRIBE_LOG` | tables | Daily `SHOW NOTEBOOKS` and `DESCRIBE NOTEBOOK` rows, stored whole as VARIANT |
| `CAPTURE_NOTEBOOK_CONFIG` | task | Fills the two tables above daily at 6:15 AM Central. **Created stopped** |
| `NOTEBOOK_SERVICE_LOG`, `CAPTURE_NOTEBOOK_SERVICES` | table, task | Notebook-managed services every 10 minutes. **Task created stopped** |
| `V_NOTEBOOK_INVENTORY`, `V_NOTEBOOK_IDLE_SETTINGS`, `V_NOTEBOOK_SERVICES_NOW` | views | Latest notebook list, idle-shutdown setting per notebook, notebook services running now |
| `V_NOTEBOOK_ACTIVITY_24H` | view | Hours each notebook service ran in the last 24h against the CPU it used (reads `UTIL_HOURLY`) |
| `V_NOTEBOOK_CREDITS_DAILY` | view | Credits and execution hours per notebook per day |

How it fits together:

- The SQL is in `monitoring/sql/*.sql.tftpl`. `${monitor_schema}` in those files is replaced with `local.schema` (top of the unit), so the schema name is written once. Edit the `.sql.tftpl` files to change the logic; edit `terragrunt.hcl` to change names, schedules and columns.
- To get the same monitoring in another account, copy the `monitoring` folder (with `sql/`) into that account's folder. Change `local.schema` if needed. The databases and rbac units need the same `ADMIN_DB.FINOPS` schema and `MONITOR_ADMIN` role there.
- The unit signs in as `MONITOR_ADMIN` (see `unit_roles`), which is created in the rbac unit with only what these objects need: create rights on that schema, `EXECUTE TASK` and `EXECUTE MANAGED TASK`, and `IMPORTED PRIVILEGES` on `SNOWFLAKE`. Add the people who run the unit to `granted_users` there. That last privilege lets the role read all of ACCOUNT_USAGE, including query text, so grant `MONITOR_ADMIN` sparingly.
- Order: databases, then rbac, then monitoring. `terragrunt run --all apply` follows the `dependencies` blocks.
- Tasks are serverless unless `local.warehouse` names a warehouse.
- Tables are never dropped by Terraform (`prevent_destroy`), because they hold history. If a plan wants to replace one, it stops. Change the table with `ALTER TABLE` in SQL instead.
- Adding more monitors is the same pattern: a table entry, a `.sql.tftpl` file for the procedure or view, a task entry. A view that reads another view in the same list needs `after_other_views = true` so it is created after the others (one level of nesting).
- Settings at the top of the unit: `event_view` (the event table view the rollup reads), `retention_days`, `snapshot_minutes` (keep equal to the capture schedules; it turns snapshot counts into hours), `idle_cpu_cores` (CPU below this counts as idle).
- **`SUSPEND_POOL_IF_IDLE` is off by default** (`idle_suspend_pool = null`). Setting a pool name creates the task *stopped* (`started = false`). Once it is started it suspends that pool at :00 and :30 between 8 and 11 PM Eastern whenever no container CPU was busy and no job service ran in the last 30 minutes. If other people's notebooks share that pool, they lose their session. The role also needs OPERATE on the pool (not in rbac yet).
- Converted from `scripts/compute_pool_monitoring_sql_only.sql`, `compute_pool_monitoring_services_addon.sql`, `suspend_pool_if_idle.sql` `egress_by_role_task.sql` and `notebook_monitoring.sql` (the last one's `MONITOR_DB.OPS` became `${monitor_schema}`, and its fixed 90 days and 10 minutes became `retention_days` and `snapshot_minutes`). The `EXECUTE TASK` and `ALTER TASK ... RESUME` lines in the originals are replaced by `started = true`. The commented discovery queries, the warehouse-side query and the "how to read the scorecard" notes were left in the original files.

Extra checks for the telemetry and services objects (none of the SQL has been run against an account):

- `SELECT COUNT(*) FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW` as `MONITOR_ADMIN`. If it fails, the role is missing access to the event table (possibly the `SNOWFLAKE.EVENTS_VIEWER` application role; not confirmed here). Also confirm the account's active event table.
- The metric, attribute and event names in `rollup_pool_telemetry.sql.tftpl` come from the original script, which says to confirm them with its discovery queries first.
- `SHOW SERVICES IN ACCOUNT` and `SHOW COMPUTE POOLS` only list what the role can see. `MONITOR_ADMIN` needs MONITOR on the pools and services (or to own them), or the snapshots will be empty.
- The column `default` on `POOL_CHANGE_LOG.CHANGED_AT` uses a provider feature (`default { expression }`) I have not run; if the plan rejects it, remove `default_expression` and fill the column when you insert.

Things to check on the first run:

- **Provider version.** `versions.tf` is `~> 2.22.1`. The task, table, view and procedure arguments here follow the 2.21/2.22 documentation. If anything breaks, check the migration guide before changing the pin.
- **Preview features.** `root.hcl` enables `snowflake_table_resource` and `snowflake_procedure_sql_resource`, following the name pattern of `snowflake_storage_integration_resource`. If `terragrunt init` or `plan` rejects a name, the error lists the valid ones. If tasks or views are also preview in your version, add them the same way.
- **Compute pool visibility.** `SHOW COMPUTE POOLS` only returns pools the task's owner role can see. `MONITOR_ADMIN` has no grants on compute pools, so `POOL_STATE_LOG` may stay empty until you grant `MONITOR` on them (not handled by the rbac unit yet).
- **Plan differences.** Column types are written as Snowflake reports them, and view statements contain commas and parentheses, which the provider warns can cause a recurring diff. Look at the first plan after apply: it should show no changes.
- **Terragrunt functions.** The unit uses `templatefile()` and `get_terragrunt_dir()` inside `inputs`. Terragrunt supports Terraform's built-in functions, but this has not been run.
- **Versions.** This code targets provider 2.22.1, Terraform 1.16.7 and Terragrunt 1.2.1, the latest stable releases on 2026-10-30 (Terraform 1.17 and Terragrunt 1.2.0 were still release candidates). Provider 2.22.0 turned on nine "experiments" by default, including `INHERITED_GRANTS` and `GRANTS_SAFE_DESTROY`, which can change how grants are read and removed. Read the provider's migration guide for 2.21 to 2.22 before the first apply, and look closely at the grant lines in the first plan.

Notebook monitoring checks (the original script flags these as unconfirmed):

- **Both notebook tasks are created stopped**, as the original script asked. Run each once by hand (`EXECUTE TASK ADMIN_DB.FINOPS.CAPTURE_NOTEBOOK_CONFIG;`, same for `CAPTURE_NOTEBOOK_SERVICES`), check the results, then set `started = true` for each in the monitoring unit and apply.
- **Field names.** `SHOW NOTEBOOKS` and `DESCRIBE NOTEBOOK` aren't fully documented, so rows are stored whole. `V_NOTEBOOK_IDLE_SETTINGS` assumes the field is `idle_auto_shutdown_time_seconds`. After the first capture, list the real fields with `SELECT DISTINCT f.key FROM ADMIN_DB.FINOPS.NOTEBOOK_DESCRIBE_LOG d, LATERAL FLATTEN(INPUT => d.raw) f;` and edit `sql/v_notebook_idle_settings.sql.tftpl` if it differs.
- **Service filter.** `CAPTURE_NOTEBOOK_SERVICES` keeps rows where `managing_object_domain ILIKE '%NOTEBOOK%'`. Check the real value with `SELECT DISTINCT managing_object_domain FROM ADMIN_DB.FINOPS.SERVICE_STATE_LOG WHERE managing_object_domain IS NOT NULL;` and edit the template if needed.
- **Visibility.** `SHOW NOTEBOOKS IN ACCOUNT` and `DESCRIBE NOTEBOOK` only cover notebooks `MONITOR_ADMIN` can see. Failed describes are logged as `{"error":"describe failed"}`; privileges are the usual cause.

****************

**AI cost management unit (budgets, enforcement, CoCo exceptions, monthly-quota exceptions, dashboard backend)**

`environment/snowflake_account_name/ai_cost_mgmt` creates these objects in `AI_COST_MGMT`, signing in as the new `AI_COST_ADMIN` role:

| Object | Kind | What it does |
| --- | --- | --- |
| `PUBLIC.AI_ROLE_BUDGETS` | table | Monthly credit limit per tier role. The rows (e.g. 50 and 100) are data: insert them in SQL |
| `PUBLIC.AI_ENFORCEMENT_LOG` | table | One row per revoke and per monthly re-grant |
| `PUBLIC.ENFORCE_CORTEX_AI_LIMITS` + `_TASK` | procedure, task | Hourly: revokes the tier role from users over budget. **Task created stopped** (see below) |
| `PUBLIC.RESET_ALL_AI_ACCESS` + `_TASK` | procedure, task | 1st of the month: re-grants tier roles. **Task created stopped** |
| `DASHBOARD.AI_DASH_USAGE_DAILY`, `AI_DASH_USER_STATUS`, `AI_DASH_COCO_24H` | tables | The dashboard's data. Transient (the schema is transient), Time Travel 0 days. Usage keeps `dash_keep_months` of history (default 6) |
| `PUBLIC.REFRESH_AI_USAGE_DASHBOARD(P_BACKFILL)` + `_TASK` | procedure, task | Hourly at :15: rebuilds the last ~31 days of usage and the two snapshot tables. Read-only on enforcement. `TRUE` reloads the full retention period |
| `COCO_LIMIT_EXCEPTION_LOG` | table | One row per user per approved CoCo daily-limit exception |
| `COCO_LIMIT_EXCEPTIONS_ACTIVE` | view | Current exceptions, for the UI and the dashboard |
| `COCO_APPLY_EFFECTIVE_LIMIT`, `COCO_GRANT_LIMIT_EXCEPTION`, `COCO_REVOKE_LIMIT_EXCEPTION`, `COCO_EXPIRE_LIMIT_EXCEPTIONS` | procedures | Apply, grant, revoke and expire exceptions |
| `COCO_EXPIRE_LIMIT_EXCEPTIONS_TASK` | task | Hourly at :05: ends expired exceptions |
| `AI_QUOTA_EXCEPTION_LOG` | table | One row per approved monthly-quota exception (temporary `AI_DATA_SCIENCE` grant) |
| `AI_QUOTA_EXCEPTIONS_ACTIVE` | view | Current monthly-quota exceptions, for the UI |
| `AI_APPLY_QUOTA_EXCEPTION`, `AI_GRANT_QUOTA_EXCEPTION`, `AI_REVOKE_QUOTA_EXCEPTION`, `AI_EXPIRE_QUOTA_EXCEPTIONS` | procedures | Apply, grant, revoke and expire monthly-quota exceptions |
| `AI_EXPIRE_QUOTA_EXCEPTIONS_TASK` | task | Hourly at :10: ends expired monthly-quota exceptions |

How it fits together:

- **Sources.** Enforcement and reset are converted unchanged from the prod procedures (`hourly_revoke.sql` and `reset_ai.sql`, taken from git history before the Nov 5 cleanup). The dashboard refresh is the retention version, `scripts/ai_usage_dashboard_refresh_retention.sql`. The exception objects are `scripts/coco_limit_exception_procedures.sql`. In every case only the `''` escaping (the provider adds the `$$` quoting itself) and the schema names changed.
- **Schemas** are set once at the top of the unit: `ai_schema` (`AI_COST_MGMT.PUBLIC`), `dash_schema` (`AI_COST_MGMT.DASHBOARD`) and `exceptions_schema`. The exception script used `admin_db.util` as a placeholder; **set `exceptions_schema` to where those objects really are in prod** before importing. If it's outside `AI_COST_MGMT`, add matching schema privileges for `AI_COST_ADMIN` in rbac.
- **Dashboard history.** `dash_keep_months` (top of the unit, default 6) is how many months of usage `AI_DASH_USAGE_DAILY` keeps, including the current one. 2 behaves like the standard two-month version. The hourly run only rebuilds the last ~31 days, so after the first apply, or after raising the setting, load the older months once with `CALL AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD(TRUE);` (a larger one-time `ACCOUNT_USAGE` scan). Lowering it needs no backfill: the next run deletes the older rows.
- **Dashboard app.** These tables are in `AI_COST_MGMT.DASHBOARD`, not `PUBLIC` as in the script. Use `ai_usage_dashboard_retention.py` (Activity tab up to 180 days) and set its `SCHEMA = "AI_COST_MGMT.DASHBOARD"` for an account built from this unit.
- **Switching an existing account from the standard refresh.** The retention procedure takes an argument, so Snowflake sees it as a different procedure from the standard one, `REFRESH_AI_USAGE_DASHBOARD()`. If the standard one exists, drop it once with `DROP PROCEDURE AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD();`.
- **Procedure arguments** are declared in UPPER CASE. The provider quotes argument names, so `P_DAYS` is what the bodies' unquoted `p_days` resolves to. A validation rule enforces it.
- **`enforcement_started = false`** creates the enforcement and reset tasks stopped. A new account shouldn't start revoking roles on the first apply. Run `CALL AI_COST_MGMT.PUBLIC.ENFORCE_CORTEX_AI_LIMITS();` by hand, check the log, then set it to `true`. For prod, set it to match the tasks' current state.
- **Session timezone.** The enforcement, reset and refresh procedures take "this month" from the task's session `TIMEZONE` parameter (the account default unless set), not from the cron timezone. Keep the three tasks on the same `TIMEZONE`.
- **Monthly-quota exceptions** raise one user's monthly budget by granting `quota_exception_role` (`AI_DATA_SCIENCE`) for a while. Enforcement checks each tier role a user holds against that role's budget, so a user holding both roles keeps access until they pass the `AI_DATA_SCIENCE` budget. The UI calls `AI_GRANT_QUOTA_EXCEPTION('USER', 'APPROVER', 'reason / ticket', NULL)`: `NULL` days runs until the next monthly reset; 1 to 31 sets a fixed length. When the last active request for a user ends, `AI_APPLY_QUOTA_EXCEPTION` revokes the role and gives back `quota_base_role` (`AI_EXPLORER`), unless enforcement revoked that role this month (then it waits for the reset). This covers a gap in the reset: it skips users who hold any tier role, so a user still on the exception role at the reset would otherwise end up with none. The grant is refused for users who already hold `AI_DATA_SCIENCE` outside an exception, or who used up its budget this month. These procedures never write to `AI_ENFORCEMENT_LOG`; they read it (the `LOGGED_AT` CHECK applies to them too). Default expiry uses the caller's session `TIMEZONE`: give the UI's session the same `TIMEZONE` as the tasks.
- Order: databases, then rbac, then ai_cost_mgmt.

Granted by hand (not in Terraform, on purpose). `AI_COST_ADMIN` gets only create rights and `IMPORTED PRIVILEGES` from rbac. Three more things are powerful enough that they should be deliberate:

```sql
-- 1. Enforcement and reset revoke and grant the tier roles. The procedures run as
--    CALLER, so the task owner (AI_COST_ADMIN) must own those roles.
GRANT OWNERSHIP ON ROLE AI_EXPLORER     TO ROLE AI_COST_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ROLE AI_DATA_SCIENCE TO ROLE AI_COST_ADMIN COPY CURRENT GRANTS;

-- 2. The exception procedures ALTER USER the three CoCo daily-limit parameters
--    (as OWNER). That needs a role able to modify those users: as in the original
--    script, ACCOUNTADMIN or a role with enough privileges on the user objects.
--    Decide this with your security team; it isn't granted here.

-- 3. Read access for the exception UI and the dashboard app (names are placeholders).
GRANT USAGE ON DATABASE AI_COST_MGMT TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON SCHEMA AI_COST_MGMT.PUBLIC TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON PROCEDURE AI_COST_MGMT.PUBLIC.COCO_GRANT_LIMIT_EXCEPTION(VARCHAR, VARCHAR, NUMBER, VARCHAR, VARCHAR, NUMBER) TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON PROCEDURE AI_COST_MGMT.PUBLIC.COCO_REVOKE_LIMIT_EXCEPTION(VARCHAR, VARCHAR) TO ROLE COCO_EXCEPTION_UI;
GRANT SELECT ON VIEW AI_COST_MGMT.PUBLIC.COCO_LIMIT_EXCEPTIONS_ACTIVE TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON PROCEDURE AI_COST_MGMT.PUBLIC.AI_GRANT_QUOTA_EXCEPTION(VARCHAR, VARCHAR, VARCHAR, NUMBER) TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON PROCEDURE AI_COST_MGMT.PUBLIC.AI_REVOKE_QUOTA_EXCEPTION(VARCHAR, VARCHAR) TO ROLE COCO_EXCEPTION_UI;
GRANT SELECT ON VIEW AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTIONS_ACTIVE TO ROLE COCO_EXCEPTION_UI;

GRANT USAGE  ON SCHEMA AI_COST_MGMT.DASHBOARD TO ROLE <APP_OWNER_ROLE>;
GRANT SELECT ON ALL TABLES IN SCHEMA AI_COST_MGMT.DASHBOARD TO ROLE <APP_OWNER_ROLE>;
```

Grants made by hand on a view or procedure are lost if Terraform ever replaces that object (for example after a body change that forces re-creation). Check the plan for replacements of the two `..._ACTIVE` views and the four UI procedures, and re-run section 3 if they are replaced.

Bringing the prod objects under management. `AI_COST_MGMT`, `AI_ROLE_BUDGETS`, `AI_ENFORCEMENT_LOG`, the two procedures and tasks, and the exception objects already exist in prod. Before the first apply there:

1. **Check the table definitions.** Compare `DESC TABLE` for `AI_ROLE_BUDGETS` and `AI_ENFORCEMENT_LOG` with the columns in the unit (marked `CHECK`). The column types, and the name of the log's timestamp column (assumed `LOGGED_AT`), were not available here. If the name differs, change it in the unit and in `sql/refresh_ai_usage_dashboard.sql.tftpl` (3 places).
2. **Check the task names and schedules** (marked `CHECK`) against `SHOW TASKS IN SCHEMA AI_COST_MGMT.PUBLIC;`.
3. **Import**, then plan. The ID formats below follow the provider's identifiers guide but haven't been verified against 2.22 (as with users and grants above): try one, and adjust if it's rejected.
   ```
   # databases unit
   terragrunt import 'snowflake_database.managed_dbs["ai_cost_mgmt"]' 'AI_COST_MGMT'
   # ai_cost_mgmt unit (one per object; procedures include their argument types)
   terragrunt import 'snowflake_table.managed_tables["AI_COST_MGMT.PUBLIC.AI_ROLE_BUDGETS"]' '"AI_COST_MGMT"."PUBLIC"."AI_ROLE_BUDGETS"'
   terragrunt import 'snowflake_procedure_sql.managed_procedures["AI_COST_MGMT.PUBLIC.ENFORCE_CORTEX_AI_LIMITS"]' '"AI_COST_MGMT"."PUBLIC"."ENFORCE_CORTEX_AI_LIMITS"()'
   terragrunt import 'snowflake_task.managed_tasks["AI_COST_MGMT.PUBLIC.ENFORCE_CORTEX_AI_LIMITS_TASK"]' '"AI_COST_MGMT"."PUBLIC"."ENFORCE_CORTEX_AI_LIMITS_TASK"'
   ```
4. **Plan and run the plan guard.** The procedure bodies were reformatted (the `''` became `'`), so expect the procedures to show an update the first time. They shouldn't be replaced: if the plan shows a replacement, stop and check before applying.
5. **Monthly-quota exception objects are new**: nothing to import, the first apply creates them. They need hand grant 1 (ownership of both tier roles) before the first Accept.
6. **The procedures' owner changes** if they were created by another role. Snowflake procedures run as their owner (or caller), so confirm `AI_COST_ADMIN` holds the hand grants above before the first enforcement run.

Known issues in the prod enforcement procedures, kept as-is here so the unit matches prod (fixes are drafted in `hourly_revoke_v2.sql` and `reset_ai_v2.sql`, not applied):

- `GRANTS_TO_USERS` lags up to about two hours, so a user revoked at 10:00 can be revoked and logged again at 11:00.
- One failed `REVOKE` stops the loop for every user after it.
- A user revoked late on the last day of the month can still look like a role holder when the reset runs, and is skipped for a whole month.
- CoCo in Snowsight and Desktop is not counted toward the monthly budget (only the CLI is). The dashboard shows it as "not counted".

## Protections against destroying objects and disturbing existing grants

Three layers, from outermost to innermost.

1. **Destroy hook (root.hcl).** `terragrunt destroy` and `terragrunt run --all destroy`
   stop immediately unless `ALLOW_DESTROY=yes` is set. Test: run `terragrunt destroy`
   in one unit without the variable; it must print `BLOCKED` and exit non-zero.
   Unverified: that a hook in `root.hcl` merges with each unit's own `terraform { source }`
   block. If the test does not block, move the `terraform { source = ... }` line into
   `root.hcl` or copy the hook into each unit.
2. **`prevent_destroy` (main.tf).** Terraform refuses any plan that destroys or replaces
   databases, replica databases, schemas, warehouses, network policies, storage
   integrations, account roles, users (both kinds), schema ownership grants and tables.
   A rename of a protected object is a replacement, so it is blocked too.
   Not protected, on purpose: views, procedures, tasks (they are code and are rebuilt),
   and the privilege/role grants (see 3).
   Limit: it only applies while the resource block still exists. Deleting a map entry from
   a unit's inputs removes the resource instance from the plan; for `for_each` resources that
   removes the instance and Terraform will then try to destroy it and fail on prevent_destroy.
   To retire an object deliberately: `terragrunt state rm '<address>'` (leaves it in Snowflake),
   or remove it after setting `ALLOW_DESTROY=yes` and temporarily deleting the lifecycle line.
3. **Plan guard (`scripts/plan_guard.py`).** Run after every plan:
   ```
   terragrunt plan -out=tfplan
   terragrunt show -json tfplan > plan.json
   python3 ../../../scripts/plan_guard.py plan.json
   ```
   It fails on any delete or replace, and also on any grant being revoked (add
   `--allow-grant-revokes` once you have read them). Grants being added are listed.
   It reads Terraform's JSON plan, which has a stable format, but it has only been tested
   against hand-written plan files here, not a real plan.

### Grants that already exist in the account

- Terraform only manages what is in state. A grant made by hand is not touched by plans,
  except that the privilege-grant resources for a role/object pair manage the listed privileges
  only (not every privilege on that object). Whether the 2.22 provider changes this default
  (`strict_privilege_management`, and the experiments enabled by default in 2.22.0) was not
  confirmed from the documentation reachable here: check the first plan for unexpected revokes.
- Creating a grant that already exists is not an error in Snowflake, but Terraform then owns it
  and removes it if you later delete it from config. Run the plan guard before applying so that
  new grants are listed, and `terragrunt import` anything you want kept under management first.
- Roles created outside Terraform are never destroyed: they are not in state. Only SYSADMIN,
  SECURITYADMIN, ACCOUNTADMIN, USERADMIN and PUBLIC are skipped by name when granting.
- New validation on `account_roles`: no role may inherit ACCOUNTADMIN, SECURITYADMIN or
  USERADMIN, no users may be assigned to those three, and `account_privileges` may not
  contain ALL, ALL PRIVILEGES or MANAGE GRANTS.
- Ownership transfers (`schema_ownership`) use `outbound_privileges = "COPY"` so existing
  grants on the schema survive the transfer. What happens to ownership when the resource is
  destroyed is not documented; it is protected for that reason.

## Bringing existing objects under management (`scripts/gen_imports.py`)

For roles, warehouses, databases and schemas that already exist in the account:

1. Export from Snowsight as CSV: `SHOW ROLES` -> `roles.csv`, `SHOW WAREHOUSES` ->
   `warehouses.csv`, `SHOW DATABASES` -> `databases.csv`, `SHOW SCHEMAS IN ACCOUNT` ->
   `schemas.csv`, all in one folder.
2. `python3 scripts/gen_imports.py <folder> > imports.tf` (add `--only names.txt` to limit it
   to the names you list, one per line, schemas as `DB.SCHEMA`).
3. Put the file in the unit that owns those objects (roles -> rbac, warehouses -> warehouses,
   databases and schemas -> databases) and run `terragrunt plan`, then `plan_guard.py`.
4. After the import apply, the next plan should show no changes. If it does, the unit's
   inputs differ from Snowflake: change the inputs, not the account. Delete `imports.tf`
   once the import has been applied.

Limits: the generated addresses assume the input map keys are the UPPER CASE names (schemas
`"DB.SCHEMA"`). Users and grants are not covered because their import ids have more parts
and the format for provider 2.22 has not been verified; import one of each by hand first.
Tested only on sample CSV files, not on a real export or a real import.
