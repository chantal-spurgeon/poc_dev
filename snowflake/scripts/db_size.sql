use role accountadmin;

use database snowflake;

use schema account_usage;

-- Size of entire database
select sum(bytes/1024/1024/1024) as "Size in GB" 
from snowflake.account_usage.tables
where table_catalog = '<db_name>'
and deleted is null;


-- Size of entire schema
select sum(bytes/1024/1024/1024) as "Size in GB" 
from snowflake.account_usage.tables
where table_catalog = '<db_name>'
and table_schema = '<schema_name>'
and deleted is null;


-- Size of entire database per table_storage_metrics
select sum(active_bytes/1024/1024/1024) as "Active Size in GB",
sum(time_travel_bytes/1024/1024/1024) as "Time Travel Size in GB",
sum(failsafe_bytes/1024/1024/1024) as "Failsafe Size in GB"
from idn_prod_db.information_schema.table_storage_metrics
where table_catalog = '<db_name>'
;


-- Size of entire schema per table_storage_metrics
select sum(active_bytes/1024/1024/1024) as "Active Size in GB",
sum(time_travel_bytes/1024/1024/1024) as "Time Travel Size in GB",
sum(failsafe_bytes/1024/1024/1024) as "Failsafe Size in GB"
from idn_prod_db.information_schema.table_storage_metrics
where table_catalog = '<db_name>'
and table_schema = '<schema_name>'
;
