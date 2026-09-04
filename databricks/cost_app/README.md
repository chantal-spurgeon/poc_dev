# Databricks Cost Explorer

A Streamlit dashboard that breaks down Databricks costs by category
(All-Purpose Compute, Jobs Compute, SQL Warehouses, DLT/Lakeflow, Model
Serving/AI, Vector Search), with drill-downs by workspace, cluster,
SQL warehouse, user, and tag.

Runs in two modes, auto-detected at startup:
- **Databricks Apps** — deployed natively in a workspace. Auth is injected
  automatically by the platform; no login needed.
- **Standalone** — run locally with `streamlit run app.py`, either against
  demo data or a real workspace via a sidebar login form.

## How this differs from a Snowflake-style cost app

Worth knowing up front, since the billing models aren't a 1:1 match:

- **No Storage category.** Databricks doesn't bill for storage directly —
  your data lives in your own S3/ADLS/GCS bucket, billed by the cloud
  provider. Check your cloud bill for that, not this app.
- **No single flat price.** Snowflake has one $/credit rate; Databricks has
  a different $/DBU rate per SKU (Jobs Compute vs. SQL Warehouses vs.
  Serverless, etc.), stored in `system.billing.list_prices` as a
  Type-2 slow-changing dimension. This app joins usage against that table
  rather than using one fixed price assumption. The sidebar's "discount %"
  applies uniformly on top of list price — set it if you have a negotiated
  committed-use discount.
- **Categories are heuristic.** There's no single documented enum of every
  `billing_origin_product` value, so categories here are inferred by
  matching keywords in `sku_name` (which does follow stable, documented
  naming conventions). The raw `sku_name` is always shown in the detail
  view and the "Breakdown by SKU" section so you can verify or adjust the
  classification in `classify_sku()` if your account has SKUs that don't
  match the built-in rules.
- **Tags are a map, not a column.** `custom_tags` on `system.billing.usage`
  is a key/value map, so you tell the app which tag key to break down by
  (e.g. `team`, `cost-center`) via the sidebar, rather than there being one
  fixed "query tag" column like Snowflake's `QUERY_TAG`.

## Option A: Deploy as a Databricks App (recommended)

1. Files needed: `app.py`, `app.yaml`, `requirements.txt`.
2. Edit `app.yaml`: replace `REPLACE_WITH_YOUR_WAREHOUSE_ID` with the ID of a
   SQL Warehouse the app should use to run queries (any small serverless
   warehouse works fine — the system tables themselves are the heavy part,
   not this app's queries).
3. Deploy via CLI:
   ```bash
   databricks apps create databricks-cost-explorer
   databricks workspace import-dir . /Workspace/Users/<you>/databricks-cost-explorer --overwrite
   databricks apps deploy databricks-cost-explorer \
     --source-code-path /Workspace/Users/<you>/databricks-cost-explorer
   ```
   Or use the Databricks Apps UI in your workspace (Compute > Apps > Create
   App) and point it at this folder.
4. **Permissions**: an account admin + metastore admin must grant `USE` and
   `SELECT` on the system schemas to the identity running the app:
   ```sql
   GRANT USE ON SCHEMA system.billing TO `<principal>`;
   GRANT SELECT ON TABLE system.billing.usage TO `<principal>`;
   GRANT SELECT ON TABLE system.billing.list_prices TO `<principal>`;
   GRANT USE ON SCHEMA system.compute TO `<principal>`;
   GRANT SELECT ON TABLE system.compute.clusters TO `<principal>`;
   GRANT SELECT ON TABLE system.compute.warehouses TO `<principal>`;
   ```
   Some system schemas also need to be explicitly enabled first — see
   Databricks' "Enable system table schemas" docs if a table shows as
   nonexistent rather than a permissions error.
5. Open the app from the workspace's **Apps** page. It detects it's running
   in Databricks Apps and skips the login form automatically.

## Option B: Run standalone (local machine / your own server)

1. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```
2. Run the app:
   ```bash
   streamlit run app.py
   ```
3. The app opens with **demo data** enabled by default, so you can explore
   it immediately with no connection.

### Connecting to a real workspace (standalone mode)

1. In the sidebar, uncheck **"Use demo data"**.
2. Fill in your workspace URL, a SQL Warehouse HTTP path (Warehouses tab >
   your warehouse > Connection details), and a personal access token.
3. Click **Connect**.

## Required system tables (both modes)

- `system.billing.usage` — usage records (DBUs, SKU, cluster/warehouse/job
  IDs, user, tags)
- `system.billing.list_prices` — historical $/DBU by SKU
- `system.compute.clusters` — cluster_id → cluster_name lookup
- `system.compute.warehouses` — warehouse_id → warehouse_name lookup

If any of these come back with an error, the app's diagnostics panel will
show the exact SQL error rather than silently showing no data — check there
first (usually a missing grant, or a system schema that hasn't been enabled
for your metastore yet).
