# Snowflake Data Ingestion Strategy

## 1. Initial Approach for Messy, Undocumented Data
The best approach to load messy, undocumented raw data into Snowflake is to ingest it into a **variant column** inside a landing table (Schema-on-Read approach) and then use Snowflake's metadata discovery functions to analyze it.

### Step-by-Step Ingestion Strategy
* **Stage the File**: Upload raw data to an internal or external Snowflake Stage.
* **Infer the File Format**: Use Snowflake's `INFER_SCHEMA` function to automatically detect column names, data types, and nullability.
* **Load Into a Landing Table**: Create a flexible staging table using a `VARIANT` data type to prevent loading failures caused by schema mismatches.
* **Query and Flatten**: Query the variant column using dot or bracket notation, and use `FLATTEN` for nested arrays.
* **Generate a Data Dictionary**: Run `DESCRIBE TABLE` or check `INFORMATION_SCHEMA.COLUMNS` to inspect structures.

---

## 2. Optimized Approach for Large Parquet Files (1 Million+ Rows)
Parquet files store their own schema metadata, making them much easier to handle than messy CSVs. 

### SQL Workflow
```sql
-- Step 1: Create a File Format
CREATE OR REPLACE FILE FORMAT my_parquet_format
  TYPE = 'PARQUET'
  COMPRESSION = 'AUTO';

-- Step 2: Infer the Schema (No Data Dictionary Needed)
SELECT * 
FROM TABLE(
  INFER_SCHEMA(
    LOCATION=>'@my_stage/large_file.parquet',
    FILE_FORMAT=>'my_parquet_format'
  )
);

-- Step 3: Automatically Create the Table
CREATE OR REPLACE TABLE target_table
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION=>'@my_stage/large_file.parquet',
        FILE_FORMAT=>'my_parquet_format'
      )
    )
  );

-- Step 4: Fast Parallel Load (Match by Name)
COPY INTO target_table
FROM @my_stage/large_file.parquet
FILE_FORMAT = (FORMAT_NAME = 'my_parquet_format')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

## 3. Recurring Production Pipeline Architecture
For a recurring production pipeline handling large Parquet batches, you need an automated, scalable structure that minimizes compute costs and handles potential schema evolution.

### Pattern A: Snowpipe with Schema Evolution (Fully Automated)
Best if files arrive continuously in cloud storage (S3, Azure Blob, or GCS).

```sql
-- 1. Enable Schema Evolution on the Target Table
ALTER TABLE target_table SET ENABLE_SCHEMA_EVOLUTION = TRUE;

-- 2. Create a Production Pipe
CREATE OR REPLACE PIPE my_parquet_pipe
AUTO_INGEST = TRUE
AS
COPY INTO target_table
FROM @my_stage/
FILE_FORMAT = (FORMAT_NAME = 'my_parquet_format')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

### Pattern B: Dynamic Tables (ELT / Declarative Approach)
Best if you prefer a scheduled batch approach (e.g., hourly or nightly) instead of continuous streaming.

```sql
-- 1. Load Raw Data to a Raw Variant Table
CREATE OR REPLACE TABLE raw_landing (
  file_name STRING,
  inserted_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  src_payload VARIANT
);

-- 2. Create a Dynamic Table to Parse and Clean
CREATE OR REPLACE DYNAMIC TABLE analytical_dim_users
  TARGET_LAG = '1 hour'
  WAREHOUSE = my_wh
  AS
  SELECT 
    src_payload:user_id::INT AS user_id,
    src_payload:email::STRING AS email,
    src_payload:signup_date::DATE AS signup_date,
    inserted_at AS load_timestamp
  FROM raw_landing;
```

### Key Production Safeguards
* **File Purging**: Keep a 14-day history in your cloud bucket for debugging initially by configuring `PURGE = FALSE`.
* **Error Handling**: Add `ON_ERROR = 'SKIP_FILE'` or `'CONTINUE'` to prevent a single corrupt row from breaking the pipeline.