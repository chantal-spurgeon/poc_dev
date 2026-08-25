CREATE OR REPLACE PROCEDURE remove_table_duplicates(table_name STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.14'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
def run(session, table_name):
    # Load the table data
    df = session.table(table_name)
    
    # Drop exact duplicates using Snowpark
    df_clean = df.drop_duplicates()
    
    # Overwrite the original table with clean data
    df_clean.write.mode("overwrite").save_as_table(table_name)
    
    return f"Successfully removed duplicates from {table_name}."
$$;

CALL remove_table_duplicates('<table_name>');
