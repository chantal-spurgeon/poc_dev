-- Clone table for backup
CREATE OR REPLACE TABLE <table_name>_backup 
CLONE <table_name>;

-- Create staging table
CREATE OR REPLACE TABLE <table_name>_staging 
LIKE <table_name>;

-- Insert only unique records
INSERT INTO <table_name>_staging
SELECT * 
FROM <table_name>
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY <partition_fields_comma_separated> 
    ORDER BY <unique_idenifier_or_insert_time_field> DESC -- Keeps the newest record (use ASC for oldest)
) = 1;

-- Swap tables. This transfers permissions to new, clean table.
ALTER TABLE <table_name> 
SWAP WITH <table_name>_staging;

-- Drop stage once you verify.
DROP TABLE my_large_table_staging;

-- Rollback command. Use stage instead of backup if stage has not yet been dropped.
-- Run ONLY if you need to reverse the entire process
ALTER TABLE <table_name> 
SWAP WITH <table_name>_backup;
