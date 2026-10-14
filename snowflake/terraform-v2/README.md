# Snowflake Terraform, one stack per area

Each area of the account (roles and grants, databases, warehouses, users, ...) is its
own **stack**: its own folder, its own state, its own tfvars. Changing a role runs
Terraform in `rbac/` only, so it cannot plan or apply anything against warehouses,
databases or users.

```
terraform-v2/
├── modules/
│   └── rbac/                 reusable code (no provider config, no state)
└── accounts/
    └── dev/                  one folder per Snowflake account
        └── rbac/             one folder per stack = one state
            ├── main.tf               calls modules/rbac
            ├── providers.tf          provider + the role this stack signs in with
            ├── versions.tf           Terraform / provider versions, S3 backend
            ├── variables.tf
            ├── backend.hcl           where the state lives (no secrets)
            ├── connection.auto.tfvars  org / account / user (no secrets)
            └── roles.auto.tfvars     <- the file you edit
```

Only `rbac` exists so far. `databases`, `warehouses`, `integrations`, `security` and
`users` follow the same pattern: a module under `modules/` and a folder per account
under `accounts/<account>/`.

## Rules the layout relies on

1. **One stack, one state.** Never share a state between stacks.
2. **Stacks refer to each other by name, not by reference.** The rbac stack writes
   `DB_STRAY_KIDS.COMEBACKS`; it does not look the schema up in another state. That
   keeps stacks independent, at the cost that a wrong name fails when applied.
3. **Names are written UPPER CASE exactly as Snowflake has them.** The code never
   changes case. This removes the case-mismatch bug that silently skipped every
   schema and object grant in the old code.
4. **Apply order on a new account:** databases, warehouses, integrations, users,
   then rbac. Later changes can be applied in any order.
5. **Each stack signs in with the least-privileged role that can do its job**
   (`snowflake_role` in `providers.tf`). Suggested: SYSADMIN for databases and
   warehouses, SECURITYADMIN for rbac, USERADMIN for users, ACCOUNTADMIN only for
   storage integrations.

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

### One-time bootstrap (as an admin, in Snowflake)

```sql
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

`SECURITY_ADMIN_CUSTOM` and its two inheritance grants are intentionally not mapped:
`SECURITY_MONITOR` replaces them.

## Tests

`modules/rbac/tests/rbac.tftest.hcl` runs against a mock provider, so it needs no
Snowflake account. It checks that every grant in a sample input becomes a resource
(the regression test for the old case-mismatch bug) and that bad input is rejected.

```bash
cd modules/rbac
terraform init -backend=false
terraform test
```

## Known gaps

* **Never run.** Terraform, OpenTofu and the provider could not be installed where
  this was written (package registries were unreachable), so nothing here has been
  through `terraform validate`, `terraform test` or `plan`. It was checked by reading
  against the provider documentation and against the old state. Run these in order:
  `terraform test` in `modules/rbac`, then `init`, `validate` and `plan` in
  `accounts/dev/rbac` against the trial account. Expect the first run to turn up small
  syntax or schema errors; the tests are there so they show up quickly.
* The other stacks (databases, warehouses, users, integrations, security) are not
  written yet.
* Granting `SNOWFLAKE.SECURITY_VIEWER` may need ACCOUNTADMIN rather than SECURITYADMIN.
  If the first apply refuses it, run that one grant as ACCOUNTADMIN.
* Requires Terraform 1.11 or newer. If your employer's pipelines pin an older
  version, `use_lockfile` in `backend.hcl` is the first thing to change (use a
  DynamoDB lock table instead).
