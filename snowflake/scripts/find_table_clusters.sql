select 'select system$clustering_information(''' 
    || table_catalog || '.' ||table_schema|| '.' || table_name
    || ''',''' || clustering_key || '''); --' || auto_clustering_on
from snowflake.account_usage.tables
where deleted is null
and clustering_key is not null
order by table_catalog, table_schema, table_name;

alter table <table> cluster by (<columns in order of priority separated by comma>);
