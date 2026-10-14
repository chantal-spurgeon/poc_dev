# Snowflake Terraform, one stack per area

Each area of the account (roles and grants, databases, warehouses, users, ...) is its
own **stack**: its own folder, its own state, its own tfvars. Changing a role runs
Terraform in `rbac/` only, so it cannot plan or apply anything against warehouses,
databases or users.

```
terraform-v2/
├── modules/                  reusable code (no provider config, no state)
│   ├── rbac/  databases/  warehouses/  integrations/  security/  users/
│   └── each with tests/      offline tests against a mock provider
├── scripts/
│   └── check_names.py        checks that the stacks agree on names
└── accounts/
    └── dev/                  one folder per Snowflake account
        ├── rbac/             one folder per stack = one state
        │   ├── main.tf               calls modules/rbac
        │   ├── providers.tf          provider + the role this stack signs in with
        │   ├── versions.tf           Terraform / provider versions, S3 backend
        │   ├── variables.tf
        │   ├── backend.hcl           where the state lives (no secrets)
        │   ├── connection.auto.tfvars  org / account / user (no secrets)
        │   └── roles.auto.tfvars     <- the file you edit
        ├── databases/        same files; you edit databases.auto.tfvars
        ├── warehouses/       ... warehouses.auto.tfvars
        ├── integrations/     ... integrations.auto.tfvars
        ├── security/         ... security.auto.tfvars (network policies)
        └── users/            ... users.auto.tfvars
```

All six stacks follow one pattern: a module under `modules/` and a folder per account
under `accounts/<account>/`. To add a new area (resource monitors, say), copy a stack,
rename it, and change the module, the sign-in role, the backend key and the tfvars.
For a second account, copy `accounts/dev` to `accounts/prod` and change the
`connection.auto.tfvars` and `backend.hcl` files.

## Rules the layout relies on

1. **One stack, one state.** Never share a state between stacks.
2. **Stacks refer to each other by name, not by reference.** The rbac stack writes
   `DB_STRAY_KIDS.COMEBACKS`; it does not look the schema up in another state. That
   keeps stacks independent. Run `python3 scripts/check_names.py` to catch a wrong name
   before it fails an apply (see "Checking that names line up").
3. **Names are written UPPER CASE exactly as Snowflake has them.** The code never
   changes case. This removes the case-mismatch bug that silently skipped every
   schema and object grant in the old code.
4. **Apply order on a new account:** databases, warehouses, integrations, security,
   users, then rbac. Later changes can be applied in any order.
5. **Each stack signs in with the least-privileged role that can do its job**
   (`snowflake_role` in `providers.tf`). SYSADMIN for databases and warehouses,
   SECURITYADMIN for rbac, security and users, and for integrations a custom role that
   holds only CREATE INTEGRATION. Nothing signs in as ACCOUNTADMIN.

## Running a stack

```bash
cd accounts/dev/rbac
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

The `*.auto.tfvars` files load by themselves, so there are no `-var-file` flags.
Commit the `.terraform.lock.hcl` file that `init` creates.

Requires Terraform 1.11 or newer (S3-native state locking). With tfenv:
`tfenv install latest:^1.11 && tfenv use latest:^1.11`.

## Authentication and secrets

* **Key-pair (JWT) authentication for a dedicated service user per stack**, not a
  personal login. The private key and passphrase are read by the provider from the
  environment, so they are not Terraform variables and never reach a tfvars file,
  a plan, or module inputs:

  ```bash
  export SNOWFLAKE_PRIVATE_KEY="$(cat ~/.ssh/tf_rbac_svc.p8)"
  export SNOWFLAKE_PRIVATE_KEY_PASSPHRASE="$(security find-generic-password -s tf_rbac_svc -w)"  # macOS keychain
  ```

  Generate an encrypted key: `openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 aes-256-cbc -inform PEM -out ~/.ssh/tf_rbac_svc.p8`,
  then `openssl rsa -in ~/.ssh/tf_rbac_svc.p8 -pubout -out ~/.ssh/tf_rbac_svc.pub`.
  For CI, the provider also supports the `WORKLOAD_IDENTITY` authenticator, which
  avoids long-lived keys altogether (see the provider docs).
* **State is sensitive.** The provider documents that sensitive values are stored as
  plaintext in state. Use the S3 backend with a private bucket (block public access,
  versioning, encryption, access limited to the people and CI role that apply). Keep
  `*.tfstate*` out of git (see `.gitignore`).
* **Restrict the service users** with a network policy and keep them key-pair only.

### One-time bootstrap for the stacks (as an admin, in Snowflake)

Each stack signs in as its own service user. These users are created by hand, once, and
are deliberately **not** in `users.auto.tfvars`: if they were, a typo in the users stack
could remove the account Terraform itself signs in with.

| Stack | Service user | Signs in as |
| --- | --- | --- |
| rbac | `TF_RBAC_SVC` | SECURITYADMIN |
| databases | `TF_DATABASES_SVC` | SYSADMIN |
| warehouses | `TF_WAREHOUSES_SVC` | SYSADMIN |
| integrations | `TF_INTEGRATIONS_SVC` | `TF_INTEGRATION_ADMIN` (custom role, below) |
| security | `TF_SECURITY_SVC` | SECURITYADMIN |
| users | `TF_USERS_SVC` | SECURITYADMIN |

```sql
-- repeat for each row of the table, with that row's user, key and role
USE ROLE USERADMIN;
CREATE USER TF_RBAC_SVC
  TYPE = SERVICE
  RSA_PUBLIC_KEY = '<public key body, no header or footer>'
  DEFAULT_ROLE = SECURITYADMIN
  COMMENT = 'Terraform rbac stack';

USE ROLE SECURITYADMIN;
GRANT ROLE SECURITYADMIN TO USER TF_RBAC_SVC;
-- then attach a network policy to the user
```

For the integrations stack, first create the custom role that holds the one privilege it
needs, so that automation never needs ACCOUNTADMIN. It is not managed in the rbac stack
on purpose (the rbac stack grants on integrations, which must exist first):

```sql
USE ROLE USERADMIN;
CREATE ROLE TF_INTEGRATION_ADMIN;

USE ROLE ACCOUNTADMIN;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE TF_INTEGRATION_ADMIN;

USE ROLE SECURITYADMIN;
GRANT ROLE TF_INTEGRATION_ADMIN TO ROLE SYSADMIN;
GRANT ROLE TF_INTEGRATION_ADMIN TO USER TF_INTEGRATIONS_SVC;
```

Create the state bucket first (private, versioned, encrypted) and put its name in
`backend.hcl`.

## Editing roles (`roles.auto.tfvars`)

Everything about a role sits in one block:

```hcl
PRODUCER = {
  comment        = "Role for 3RACHA"
  inherits       = []                         # roles this role receives
  users          = ["BANGCHAN"]
  database_roles = []                         # e.g. "SNOWFLAKE.SECURITY_VIEWER"
  account_privileges = []                     # e.g. "CREATE DATABASE"
  databases      = { DB_STRAY_KIDS = ["USAGE"] }
  warehouses     = { PRODUCER_WH = ["USAGE", "OPERATE"] }
  integrations   = { AWS_S3_DATA_LAKE = ["USAGE"] }
  schemas = {
    "DB_STRAY_KIDS.COMEBACKS" = {
      privileges = ["USAGE", "CREATE TABLE"]
      owner      = false                      # true = transfer schema ownership
      objects = {
        TABLES = { current = ["SELECT"], future = ["SELECT"] }
      }
    }
  }
}
```

Mistakes are caught at plan time, before anything is applied: lower-case names,
`OWNERSHIP` listed as a privilege, INSERT/UPDATE/DELETE on views, an unknown object
type, a role that inherits a role that does not exist.

### Guardrails against privilege escalation

Two module variables set the policy (`modules/rbac/variables.tf`). Changing either
is a deliberate, reviewed decision, not a tfvars edit:

| Variable | Default | Effect |
| --- | --- | --- |
| `protected_roles` | ACCOUNTADMIN, SECURITYADMIN, USERADMIN | No role may inherit them, and they cannot be granted to users here. Grant them by hand. |
| `denied_privileges` | ALL, ALL PRIVILEGES, MANAGE GRANTS | Rejected wherever a privilege list appears. |

SYSADMIN is deliberately not protected: custom roles are rolled up under it.

`current` grants cover objects that exist when you apply. `future` grants cover
objects created afterwards. Most roles need both.

## Databases (`databases.auto.tfvars`)

Signs in as SYSADMIN, as a service user of its own (`TF_DATABASES_SVC`). Everything
about a database sits in one block:

```hcl
DB_STRAY_KIDS = {
  comment                  = "Production chaos."
  is_transient             = true      # no Fail-safe; Time Travel limited to 1 day
  data_retention_time_days = 1
  schemas = {
    COMEBACKS = { comment = "The final product we love", managed_access = true }
  }
}
```

Caught at plan time: lower-case names, Snowflake's own databases (`SNOWFLAKE`, ...),
Time Travel above 90 days (above 1 for transient), a permanent schema in a transient
database, schemas on a replica, a malformed `replica_of`. A schema is transient like
its database unless it says otherwise. The rbac stack grants on these objects by the
same names; the `schemas` output lists the exact spellings.

`managed_access = true` is recommended for shared schemas. It defaults to false
because that matches the old code.

### Retiring a database or schema

Databases and schemas carry `prevent_destroy`. Removing one from the tfvars, or a
change that would force Terraform to recreate it, stops with an error instead of
dropping data. To retire one on purpose:

1. Stop Terraform managing it: `terraform state rm 'module.databases.snowflake_schema.schema["DB.SCHEMA"]'`
   (and the database itself, if it is going too).
2. Remove it from `databases.auto.tfvars`.
3. Drop it in Snowflake yourself. `UNDROP` works until Time Travel runs out.

Because `PRODUCER` is granted to SYSADMIN in the rbac stack, SYSADMIN can still manage
a schema whose ownership was transferred to `PRODUCER`. Keep that line if you use
`owner = true`.

## Warehouses (`warehouses.auto.tfvars`)

Signs in as SYSADMIN. Cost guardrails are built in and checked at plan time:

* `auto_suspend` is 60 to 86400 seconds. Snowflake bills at least 60 seconds each time
  a warehouse resumes, so the old 10 seconds saved nothing and emptied the cache.
* `statement_timeout_in_seconds` defaults to 3600. Snowflake's own default is two days,
  so one runaway query could otherwise run up two days of credits.
* No warehouse may exceed `max_warehouse_size` (default XXLARGE). Raising it is a
  reviewed policy change, not a tfvars edit.

```hcl
REPORTING_WH = { warehouse_size = "SMALL", auto_suspend = 120, max_cluster_count = 5 }
```

Multi-cluster warehouses (`max_cluster_count` above 1) need Enterprise edition.
Resource monitors are not covered: assigning one to a warehouse needs ACCOUNTADMIN, so
it would be a stack of its own.

## Storage integrations (`integrations.auto.tfvars`)

Signs in as `TF_INTEGRATION_ADMIN`. S3, S3GOV, S3CHINA, GCS and AZURE integrations in
one file, each routed to the right resource. Rejected at plan time: wildcard locations,
a location without a trailing `/` (without it `s3://bucket/data` also matches
`s3://bucket/data-private`), the wrong scheme for the provider, a missing or malformed
role ARN (S3) or tenant ID (Azure).

After the first apply, the cloud side must be set up to trust Snowflake. The values come
from outputs: `terraform output -json aws_trust_policy_inputs` (the external ID is a
guard against the confused-deputy attack, so that output is marked sensitive),
`gcs_service_accounts`, `azure_consent`.

## Network policies (`security.auto.tfvars`)

Signs in as SECURITYADMIN. This stack only **defines** policies. A policy does nothing
until it is attached, and attaching one to the whole account is deliberately not done
here: a wrong list would lock out everyone, including Terraform. Attach a policy to one
user with `network_policy` in the users stack, where the worst case is locking out that
user. IPv4 only; `0.0.0.0/0` is rejected in both lists. The example policy uses a
documentation address range (203.0.113.0/24): replace it before a real service user
depends on it.

## Users (`users.auto.tfvars`)

Signs in as SECURITYADMIN (USERADMIN can create users, but attaching a network policy
needs ATTACH POLICY). There are no passwords anywhere: people use single sign-on and
service users a key pair. Guardrails:

* A `SERVICE` user must have an `rsa_public_key` and a `network_policy`
  (`require_network_policy_for_service_users`, on by default).
* `default_role` cannot be ACCOUNTADMIN, SECURITYADMIN or USERADMIN, because a default
  role is active in every session, script and notebook.
* `default_secondary_roles` defaults to `NONE`. `ALL` lets a session use every role the
  user holds at once; the example keeps `ALL` for the two people because the old file
  asked for it, with a comment saying so.
* A public key must be the one-line body, at least 2048 bits. A key pasted with its
  `BEGIN` line is rejected.

## Checking that names line up

Stacks refer to each other by name, so a typo in one is invisible to the others until an
apply fails. `scripts/check_names.py` reads the tfvars files and checks every such
reference: a user's warehouse, namespace, role and policy, and a role's users, databases,
schemas, warehouses and integrations.

```bash
python3 scripts/check_names.py              # accounts/dev
python3 scripts/check_names.py accounts/prod
```

It needs only Python 3, changes nothing, and exits 1 on a mismatch, so it can run in CI
or a pre-commit hook. It reads the tfvars files as plain data, so it stops with a message
if one uses an expression or function.

## What changed from the old `terraform/` folder

| Old behavior | Now |
| --- | --- |
| One state; any run touched every area | One state per stack |
| Schema and object grants never applied (case mismatch, `COMBACKS` typo) | Names are used as written; a wrong name fails the plan or apply |
| `OWNERSHIP` on tasks and schema `MODIFY` silently dropped | Rejected by validation with a message |
| SYSADMIN inherited SECURITYADMIN via `SECURITY_ADMIN_CUSTOM` | `SECURITY_MONITOR` with the `SNOWFLAKE.SECURITY_VIEWER` database role, not under SYSADMIN |
| Runs as ACCOUNTADMIN | Each stack names its own role |
| Private key passed as a Terraform variable; key path in tfvars | Provider reads the key from the environment |
| 6 near-identical attributes per role for object grants | One `objects` map per schema |
| State committed, no lock file, no `.gitignore` | `.gitignore` included; S3 backend with locking; commit the lock file |
| Any role could inherit SECURITYADMIN or hold MANAGE GRANTS | Rejected by validation (`protected_roles`, `denied_privileges`) |
| Deleting a line could drop a database | `prevent_destroy` on databases and schemas |
| Warehouses could auto-suspend at 10 seconds and run statements for two days | `auto_suspend` 60 or more, statement timeout 3600 by default, size limit |
| Integrations could allow `*` or an unterminated path | Rejected by validation |
| Service users needed no key or network policy; passwords and `must_change_password` logic | Key pair and network policy required; no passwords |
| Users got no default warehouse, namespace or secondary-roles setting (the tfvars keys were silently dropped) | Every field in the type is passed through and validated |
| Databases, warehouses, roles and users all applied together as ACCOUNTADMIN | Databases stack signs in as SYSADMIN, alone |

## Moving from the old layout (not yet tested)

All seven old addresses in the table below were checked against the committed old
state and exist there.

**On a trial account, start clean.** The grants take seconds to recreate, and moving
state has a catch (below).

1. In Snowflake, drop the roles the old code made: `DROP ROLE PRODUCER;` and
   `DROP ROLE SECURITY_ADMIN_CUSTOM;`. Dropping a role removes the grants on it.
2. In the old folder, run `terraform state rm` for the rbac resources so the old code
   stops managing them (or retire the old state once nothing else in it matters).
3. Apply this stack. The first plan creates every schema and object grant the old
   code never applied, so read it before you apply.

**Keeping the existing objects.** Either write `import` blocks in the new stack (the
provider docs give the ID format for each resource), or move the state entries. The
mapping for a move:

| Old address (under `module.snowflake_infrastructure`) | New address (under `module.rbac`) |
| --- | --- |
| `snowflake_account_role.rbac_roles["PRODUCER"]` | `snowflake_account_role.role["PRODUCER"]` |
| `snowflake_grant_account_role.role_to_role_grants["SYSADMIN_INHERITS_PRODUCER"]` | `snowflake_grant_account_role.inheritance["SYSADMIN<-PRODUCER"]` |
| `snowflake_grant_account_role.user_to_role_grants["BANGCHAN_ASSIGNED_TO_PRODUCER"]` | `snowflake_grant_account_role.to_user["PRODUCER:BANGCHAN"]` |
| `snowflake_grant_privileges_to_account_role.database_grants["PRODUCER_DB_DB_STRAY_KIDS"]` | `snowflake_grant_privileges_to_account_role.account_object["PRODUCER:DATABASE:DB_STRAY_KIDS"]` |
| `snowflake_grant_privileges_to_account_role.warehouse_grants["PRODUCER_WH_PRODUCER_WH"]` | `snowflake_grant_privileges_to_account_role.account_object["PRODUCER:WAREHOUSE:PRODUCER_WH"]` |
| `snowflake_grant_privileges_to_account_role.integration_grants["PRODUCER_INT_AWS_S3_DATA_LAKE"]` | `snowflake_grant_privileges_to_account_role.account_object["PRODUCER:INTEGRATION:AWS_S3_DATA_LAKE"]` |
| `snowflake_grant_ownership.schema_ownership["PRODUCER_SCHEMA_DB_STRAY_KIDS.CHANS_LAPTOP"]` | `snowflake_grant_ownership.schema["PRODUCER:DB_STRAY_KIDS.CHANS_LAPTOP"]` |

The catch: the old state records these resources against the old module's own provider
configuration (`module.snowflake_infrastructure.provider["registry.terraform.io/snowflakedb/snowflake"]`).
The new stack has no such configuration, so after a move Terraform may refuse to
plan with a "provider configuration not present" error. This has not been tried here,
and it is the main reason to prefer a clean start or `import`. Work on copies of the
state files either way, and `terraform plan` should show no changes for moved
resources before you apply anything.

For the databases stack, the three old addresses (all present in the old state) map to:

| Old address (under `module.snowflake_infrastructure`) | New address (under `module.databases`) |
| --- | --- |
| `snowflake_database.managed_dbs["db_stray_kids"]` | `snowflake_database.database["DB_STRAY_KIDS"]` |
| `snowflake_schema.managed_schemas["db_stray_kids.chans_laptop"]` | `snowflake_schema.schema["DB_STRAY_KIDS.CHANS_LAPTOP"]` |
| `snowflake_schema.managed_schemas["db_stray_kids.comebacks"]` | `snowflake_schema.schema["DB_STRAY_KIDS.COMEBACKS"]` |

Do not drop these two schemas or the database to "start clean" if they hold data. Use
`import` or a state move for them, and expect the provider-address catch below.

For the other stacks, the old addresses (all present in the old state) map to:

| Old address (under `module.snowflake_infrastructure`) | New address |
| --- | --- |
| `snowflake_warehouse.managed_whs["producer_wh"]` | `module.warehouses.snowflake_warehouse.warehouse["PRODUCER_WH"]` |
| `snowflake_warehouse.managed_whs["reporting_wh"]` | `module.warehouses.snowflake_warehouse.warehouse["REPORTING_WH"]` |
| `snowflake_warehouse.managed_whs["snowpark_wh"]` | `module.warehouses.snowflake_warehouse.warehouse["SNOWPARK_WH"]` |
| `snowflake_storage_integration_aws.cloud_links["AWS_S3_DATA_LAKE"]` | `module.integrations.snowflake_storage_integration_aws.integration["AWS_S3_DATA_LAKE"]` |
| `snowflake_storage_integration_gcs.cloud_links["GCS_DATA_LAKE"]` | `module.integrations.snowflake_storage_integration_gcs.integration["GCS_DATA_LAKE"]` |
| `snowflake_user.corporate_users["bangchan"]` | `module.users.snowflake_user.person["BANGCHAN"]` |
| `snowflake_user.corporate_users["han"]` | `module.users.snowflake_user.person["HAN"]` |
| `snowflake_service_user.service_accounts["stray_kids_admin"]` | `module.users.snowflake_service_user.service["STRAY_KIDS_ADMIN"]` |

The new tfvars deliberately change a few values, so the first plan will show them:
`PRODUCER_WH` auto-suspend 10 to 60 seconds, a statement timeout of 3600 on every
warehouse, and the service user gaining a default warehouse and network policy. Every
other difference is a bug to look into.

`SECURITY_ADMIN_CUSTOM` and its two inheritance grants are intentionally not mapped:
`SECURITY_MONITOR` replaces them.

## Tests

Each module has a test file in its `tests/` folder. It runs against a mock provider, so
it needs no Snowflake account. It checks that every definition in a sample input
becomes a resource (for rbac, the regression test for the old case-mismatch bug) and
that bad input is rejected.

```bash
for m in rbac databases warehouses integrations security users; do
  (cd modules/$m && terraform init -backend=false && terraform test)
done
```

## Known gaps

* **Never run.** Terraform, OpenTofu and the provider could not be installed where
  this was written (package registries were unreachable), so nothing here has been
  through `terraform validate`, `terraform test` or `plan`. It was checked by reading
  against the provider documentation and against the old state. Run these in order:
  `terraform test` in `modules/rbac`, then `init`, `validate` and `plan` in
  `accounts/dev/rbac` against the trial account. Expect the first run to turn up small
  syntax or schema errors; the tests are there so they show up quickly.
* Provider arguments were checked against the provider docs for every resource except
  `snowflake_network_policy`, whose docs page would not load. Its arguments
  (`allowed_ip_list`, `blocked_ip_list`, `comment`) come from the old code, which never
  applied a policy, so treat that resource as the likeliest place for a first-run error.
* A new stack's service user has to exist before its first `init`. See the bootstrap.
* The databases stack was written against the provider docs for `snowflake_database`
  and `snowflake_secondary_database`. The `snowflake_schema` docs page would not load,
  so its argument types (`is_transient` and `with_managed_access` are strings) come
  from your old state instead. `data_retention_time_in_days` is left unset on schemas
  so they inherit; if the first plan shows a change there, set it explicitly.
* Granting `SNOWFLAKE.SECURITY_VIEWER` may need ACCOUNTADMIN rather than SECURITYADMIN.
  If the first apply refuses it, run that one grant as ACCOUNTADMIN.
* Requires Terraform 1.11 or newer. If your employer's pipelines pin an older
  version, `use_lockfile` in `backend.hcl` is the first thing to change (use a
  DynamoDB lock table instead).
