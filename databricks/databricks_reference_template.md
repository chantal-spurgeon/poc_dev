# Databricks Architecture & Terragrunt Reference Guide

A comprehensive template mapping technical transitions from Snowflake to Databricks using a DRY (Don't Repeat Yourself) Infrastructure as Code (IaC) design pattern.

---

## 1. Architectural Concept Mapping
*   **Storage Hierarchy:** `snowflake_database` / `schema` -> `databricks_catalog` / `schema` (Unity Catalog).
*   **Compute Engines:** `snowflake_warehouse` -> `databricks_sql_endpoint` (BI queries) & `databricks_cluster` (ETL pipelines).
*   **Identity Layer:** `snowflake_user` / `role` -> `databricks_user` / `group` / `service_principal`.
*   **Security Access:** `snowflake_grant_privileges_to_account_role` -> `databricks_grant` / `databricks_permissions`.

---

## 2. Parent Root Configuration
**File Location:** `live/terragrunt.hcl`
```hcl
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env_name      = local.account_vars.locals.environment_name
  workspace_url = local.account_vars.locals.databricks_workspace_url
}

inputs = {
  environment              = local.env_name
  databricks_workspace_url = local.workspace_url
}

remote_state {
  backend = "s3"
  generate = { path = "backend.gen.tf", if_exists = "overwrite_terragrunt" }
  config = {
    bucket         = "my-company-databricks-tfstate-${local.env_name}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "databricks-lock-table-${local.env_name}"
  }
}

generate "provider" {
  path      = "provider.gen.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.54.0" }
  }
}
provider "databricks" { host = "${local.workspace_url}" }
EOF
}
```

---

## 3. Automated Workspace Identities Module
**File Location:** `modules/identities/main.tf`
```hcl
resource "databricks_user" "users" {
  for_each  = var.databricks_users
  user_name = each.value
}

resource "databricks_group" "groups" {
  for_each     = toset(var.databricks_groups)
  display_name = each.value
}

locals {
  membership_flat = flatten([
    for group, users in var.group_memberships : [
      for user in users : {
        group_id  = databricks_group.groups[group].id
        member_id = databricks_user.users[user].id
        key       = "${group}-${user}"
      }
    ]
  ])
}

resource "databricks_group_member" "membership" {
  for_each  = { for m in local.membership_flat : m.key => m }
  group_id  = each.value.group_id
  member_id = each.value.member_id
}
```

---

## 4. Compute Budget Control (Cluster Policies)
**File Location:** `modules/cluster_policies/main.tf`
```hcl
resource "databricks_cluster_policy" "this" {
  name = var.policy_name
  definition = jsonencode({
    "autotermination_minutes" : { "type" : "fixed", "value" : var.auto_termination_minutes },
    "autoscale.max_workers"   : { "type" : "range", "maxValue" : var.max_num_workers },
    "node_type_id"            : { "type" : "allowlist", "values" : var.allowed_node_types }
  })
}
```

---

## 5. Storage Handshake & Data Object Grants
*   **Storage Credentials:** Establishes cross-account cloud access using IAM Roles (`databricks_storage_credential`).
*   **External Locations:** Restricts and registers concrete cloud folder directory paths (`databricks_external_location`).
*   **Privilege Inheritance:** Permissions defined at the Catalog/Schema level cascade cleanly onto downstream entities.

---

## 6. Orchestrated Workflow Layout
**File Location:** `modules/workflows/main.tf`
```hcl
resource "databricks_job" "daily_etl" {
  name = var.job_name
  schedule {
    quartz_cron_expression = "0 0 2 * * ?"
    timezone_id            = "UTC"
  }
  job_cluster {
    job_cluster_key = "shared_etl_compute"
    new_cluster {
      spark_version = "15.4.x-scala2.12"
      node_type_id  = "m5d.xlarge"
      num_workers   = 2
    }
  }
  task {
    task_key        = "01_data_ingestion"
    job_cluster_key = "shared_etl_compute"
    notebook_task { notebook_path = var.ingest_notebook_path }
  }
  task {
    task_key        = "02_data_transformation"
    job_cluster_key = "shared_etl_compute"
    depends_on      { task_key = "01_data_ingestion" }
    notebook_task { notebook_path = var.transform_notebook_path }
  }
}
```

---

## 7. Isolated Multi-Workspace Infrastructure Layout
```text
├── live/
│   ├── terragrunt.hcl          # Dynamic Root Engine
│   ├── dev/
│   │   ├── account.hcl        # Dev parameters & Workspace URL
│   │   └── identities/        # Child Module Target Deployment
│   └── prod/
│       ├── account.hcl        # Prod parameters & Workspace URL
│       └── workflows/
```