# objects.tf
#
# Tables, views, procedures and tasks. Same pattern as the rest of main.tf: the
# inputs say what should exist, the unit that owns them supplies the maps.
# Creation order inside a unit is tables, then views, then procedures, then tasks.

# ==============================================================================
# TABLES (log and history tables; never dropped by Terraform)
# ==============================================================================
resource "snowflake_table" "managed_tables" {
  for_each = var.tables

  database = split(".", each.key)[0]
  schema   = split(".", each.key)[1]
  name     = split(".", each.key)[2]

  comment                     = each.value.comment
  data_retention_time_in_days = each.value.data_retention_time_days
  change_tracking             = each.value.change_tracking

  dynamic "column" {
    for_each = each.value.columns
    content {
      name     = column.value.name
      type     = column.value.type
      nullable = column.value.nullable
      comment  = column.value.comment
    }
  }

  # These tables hold history. If a change would force the table to be replaced,
  # Terraform stops instead of dropping the data. Change such a table in SQL
  # (ALTER TABLE), then `terragrunt refresh`.
  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# VIEWS
# ==============================================================================
resource "snowflake_view" "managed_views" {
  for_each = var.views

  database = split(".", each.key)[0]
  schema   = split(".", each.key)[1]
  name     = split(".", each.key)[2]

  statement = each.value.statement
  comment   = each.value.comment
  is_secure = tostring(each.value.is_secure)

  depends_on = [snowflake_table.managed_tables]
}

# ==============================================================================
# STORED PROCEDURES (SQL)
# ==============================================================================
resource "snowflake_procedure_sql" "managed_procedures" {
  for_each = var.procedures

  database = split(".", each.key)[0]
  schema   = split(".", each.key)[1]
  name     = split(".", each.key)[2]

  dynamic "arguments" {
    for_each = each.value.arguments
    content {
      arg_name      = arguments.value.name
      arg_data_type = arguments.value.type
    }
  }

  return_type          = each.value.returns
  execute_as           = upper(each.value.execute_as)
  procedure_definition = each.value.body
  comment              = each.value.comment

  depends_on = [snowflake_table.managed_tables, snowflake_view.managed_views]
}

# ==============================================================================
# TASKS
# ==============================================================================
resource "snowflake_task" "managed_tasks" {
  for_each = var.tasks

  database = split(".", each.key)[0]
  schema   = split(".", each.key)[1]
  name     = split(".", each.key)[2]

  sql_statement = each.value.statement
  started       = each.value.started
  comment       = each.value.comment

  # A warehouse, or serverless compute (no warehouse, a starting size instead).
  # Serverless needs EXECUTE MANAGED TASK; both need EXECUTE TASK.
  warehouse                                = each.value.warehouse
  user_task_managed_initial_warehouse_size = each.value.warehouse == null ? each.value.serverless_size : null

  dynamic "schedule" {
    for_each = each.value.schedule == null ? [] : [each.value.schedule]
    content {
      using_cron = schedule.value.using_cron
      minutes    = schedule.value.minutes
      hours      = schedule.value.hours
    }
  }

  depends_on = [snowflake_procedure_sql.managed_procedures]
}
