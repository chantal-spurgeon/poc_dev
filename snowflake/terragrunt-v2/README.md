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

Run each unit from its own folder (`environment/snowflake_account_name/<unit>`), in this order: databases, integrations, security, warehouses, users, rbac.

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
| `V_POOL_DAILY`, `V_POOL_CREDITS_DAILY` | views | Suspends/resumes/time at max nodes, and credits per day |

How it fits together:

- The SQL is in `monitoring/sql/*.sql.tftpl`. `${monitor_schema}` in those files is replaced with `local.schema` (top of the unit), so the schema name is written once. Edit the `.sql.tftpl` files to change the logic; edit `terragrunt.hcl` to change names, schedules and columns.
- To get the same monitoring in another account, copy the `monitoring` folder (with `sql/`) into that account's folder. Change `local.schema` if needed. The databases and rbac units need the same `ADMIN_DB.FINOPS` schema and `MONITOR_ADMIN` role there.
- The unit signs in as `MONITOR_ADMIN` (see `unit_roles`), which is created in the rbac unit with only what these objects need: create rights on that schema, `EXECUTE TASK` and `EXECUTE MANAGED TASK`, and `IMPORTED PRIVILEGES` on `SNOWFLAKE`. Add the people who run the unit to `granted_users` there. That last privilege lets the role read all of ACCOUNT_USAGE, including query text, so grant `MONITOR_ADMIN` sparingly.
- Order: databases, then rbac, then monitoring. `terragrunt run --all apply` follows the `dependencies` blocks.
- Tasks are serverless unless `local.warehouse` names a warehouse.
- Tables are never dropped by Terraform (`prevent_destroy`), because they hold history. If a plan wants to replace one, it stops. Change the table with `ALTER TABLE` in SQL instead.
- Adding more monitors is the same pattern: a table entry, a `.sql.tftpl` file for the procedure or view, a task entry. The remaining scripts (`rollup_pool_telemetry`, the services add-on, `suspend_pool_if_idle`) are not converted yet. The first two need an event table, and `suspend_pool_if_idle` has a pool name to parameterise.

Things to check on the first run:

- **Provider version.** `versions.tf` is `~> 2.22.1`. The task, table, view and procedure arguments here follow the 2.21/2.22 documentation. If anything breaks, check the migration guide before changing the pin.
- **Preview features.** `root.hcl` enables `snowflake_table_resource` and `snowflake_procedure_sql_resource`, following the name pattern of `snowflake_storage_integration_resource`. If `terragrunt init` or `plan` rejects a name, the error lists the valid ones. If tasks or views are also preview in your version, add them the same way.
- **Compute pool visibility.** `SHOW COMPUTE POOLS` only returns pools the task's owner role can see. `MONITOR_ADMIN` has no grants on compute pools, so `POOL_STATE_LOG` may stay empty until you grant `MONITOR` on them (not handled by the rbac unit yet).
- **Plan differences.** Column types are written as Snowflake reports them, and view statements contain commas and parentheses, which the provider warns can cause a recurring diff. Look at the first plan after apply: it should show no changes.
- **Terragrunt functions.** The unit uses `templatefile()` and `get_terragrunt_dir()` inside `inputs`. Terragrunt supports Terraform's built-in functions, but this has not been run.
- **Versions.** This code targets provider 2.22.1, Terraform 1.16.7 and Terragrunt 1.2.1, the latest stable releases on 2026-10-30 (Terraform 1.17 and Terragrunt 1.2.0 were still release candidates). Provider 2.22.0 turned on nine "experiments" by default, including `INHERITED_GRANTS` and `GRANTS_SAFE_DESTROY`, which can change how grants are read and removed. Read the provider's migration guide for 2.21 to 2.22 before the first apply, and look closely at the grant lines in the first plan.

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
