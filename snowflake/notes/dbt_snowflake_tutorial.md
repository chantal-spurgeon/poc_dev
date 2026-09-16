# Tutorial: Connecting and Configuring dbt Core with Snowflake

Connecting **dbt Core (CLI)** with a **Snowflake data warehouse** allows you to leverage version-controlled, modular SQL to manage cloud data transformations. This document outlines the step-by-step framework for establishing and verifying this connection using best practices.

---

### Step 1: Prep Your Snowflake Environment
Before configuring dbt, you need dedicated warehouse infrastructure and proper access controls inside Snowflake. Run the following commands in a Snowflake worksheet as an administrator (or a role with sufficient privileges):

```sql
-- 1. Create a dedicated dbt architecture role
CREATE ROLE IF NOT EXISTS dbt_role;

-- 2. Create a dedicated virtual warehouse for transformations
CREATE WAREHOUSE IF NOT EXISTS dbt_warehouse 
    WITH WAREHOUSE_SIZE = 'XSMALL' 
    AUTO_SUSPEND = 60 
    AUTO_RESUME = TRUE;

-- 3. Create databases for raw ingestion and dbt outputs
CREATE DATABASE IF NOT EXISTS raw;
CREATE DATABASE IF NOT EXISTS analytics;

-- 4. Grant privileges to the role
GRANT USAGE ON WAREHOUSE dbt_warehouse TO ROLE dbt_role;
GRANT ALL PRIVILEGES ON DATABASE analytics TO ROLE dbt_role;
GRANT USAGE ON DATABASE raw TO ROLE dbt_role;

-- 5. Create a dedicated user for dbt and assign the role
CREATE USER IF NOT EXISTS dbt_user 
    PASSWORD = 'YourSecurePassword123!' 
    DEFAULT_ROLE = dbt_role;
    
GRANT ROLE dbt_role TO USER dbt_user;
```

---

### Step 2: Install dbt and the Snowflake Adapter
It is recommended to use a virtual Python environment to prevent dependency conflicts. Open your command terminal and execute:

```bash
# Create and activate a Python virtual environment
python3 -m venv dbt-env
source dbt-env/bin/activate  # On Windows use: dbt-env\Scripts\activate

# Install dbt-core and the snowflake adapter simultaneously
pip install dbt-core dbt-snowflake
```

Verify the installation succeeded by checking the version:
```bash
dbt --version
```

---

### Step 3: Initialize Your dbt Project
Navigate to the directory where you want to keep your data project and run the initialization wizard:

```bash
dbt init my_snowflake_project
```

The CLI wizard will prompt you with questions:
1. **Which database would you like to use?** Type `1` or select `snowflake`.
2. **Desired authentication method?** Select `1` for `password` (or `keypair` if you prefer advanced security).

This command autogenerates your project folder structures and creates/updates a hidden configuration file on your machine called `profiles.yml`.

---

### Step 4: Configure the `profiles.yml` File
Your connection blueprints live in `~/.dbt/profiles.yml`. Open this file in a text editor to update your Snowflake locator strings and specific target configurations. 

```yaml
my_snowflake_project:
  outputs:
    dev:
      type: snowflake
      account: abc12345.us-east-1  # Look at your Snowflake URL, omit '.snowflakecomputing.com'
      user: dbt_user
      password: YourSecurePassword123!
      role: dbt_role
      warehouse: dbt_warehouse
      database: analytics
      schema: dbt_dev_schema     # Schema where dbt will build views/tables during development
      threads: 4                 # Concurrency setting for executing models
      client_session_keep_alive: False
  target: dev
```

> **Locating your Account Identifier:** Take your Snowflake login URL (e.g., `https://xy12345.east-us-2.azure.snowflakecomputing.com`) and strip out `https://` and `.snowflakecomputing.com`. Your identifier would be `xy12345.east-us-2.azure`.

---

### Step 5: Verify the Connection
Change your terminal directory into your new project folder:

```bash
cd my_snowflake_project
```

Run the built-in debug command to test connectivity, credentials, and network paths between your machine and Snowflake:

```bash
dbt debug
```

If everything is configured correctly, your terminal will output confirmations for your `dbt_project.yml` file, local profile, and append a green **`Connection test: OK`** message at the end.

---

### Step 6: Execute an Initial Run
dbt generates sample models inside the `models/example/` directory when you initialize a project. Test your compute resources by materializing them into Snowflake:

```bash
dbt run
```

Log back into your **Snowflake Snowsight Console**. You will now see tables and views populated inside `analytics.dbt_dev_schema`.
