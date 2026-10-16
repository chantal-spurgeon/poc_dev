WITH targets AS (
    SELECT column1 AS object_name
    FROM VALUES
        ('MY_DB.MY_SCHEMA.TABLE_A'),
        ('MY_DB.MY_SCHEMA.TABLE_B'),
        ('MY_DB.MY_SCHEMA.TABLE_C')
),
access AS (
    SELECT
        obj.value:"objectName"::string AS object_name,
        ah.query_start_time,
        ah.user_name
    FROM snowflake.account_usage.access_history ah,
         LATERAL FLATTEN(input => ah.base_objects_accessed) obj
    WHERE ah.query_start_time >= DATEADD(day, -14, CURRENT_TIMESTAMP())
      AND obj.value:"objectDomain"::string = 'Table'
)
SELECT
    t.object_name,
    COUNT(a.query_start_time)      AS access_count,
    MAX(a.query_start_time)        AS last_accessed,
    LISTAGG(DISTINCT a.user_name, ', ') AS users
FROM targets t
LEFT JOIN access a ON a.object_name = t.object_name
GROUP BY t.object_name
ORDER BY access_count DESC;
