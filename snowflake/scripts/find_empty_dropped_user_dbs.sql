/*
  find_empty_dropped_user_dbs.sql

  Purpose : Inventory every database whose name starts with DROPPED_ (personal
            databases left behind when a user is dropped) and flag the ones
            that contain no objects, so they can be dropped safely.

  Run as  : A role that can see the DROPPED_ databases (e.g. ACCOUNTADMIN).
  Output  : One row per DROPPED_ database with total object count, a breakdown
            of what was found, any checks that errored, and a DROP statement
            for the ones that are empty. Nothing is dropped automatically.

  Scope   : Only objects in PUBLIC, LOCAL or other user schemas are counted;
            INFORMATION_SCHEMA is ignored. Empty schemas don't count as objects.

  Details : Per-type counts stay in the session temp table
            DROPPED_DB_INVENTORY for drill-down after the run.
*/

EXECUTE IMMEDIATE $$
DECLARE
  prefix     STRING DEFAULT 'DROPPED_';
  show_cmds  ARRAY;
  n_cmds     INTEGER;
  db_name    STRING;
  db_ident   STRING;
  obj_type   STRING;
  cnt        INTEGER;
  err        STRING;
  dbs        RESULTSET;
  result_rs  RESULTSET;
BEGIN
  -- Object types to check (each one via SHOW <type> IN DATABASE).
  -- Add or remove types here as needed. Overlap (e.g. dynamic tables also
  -- appearing under OBJECTS) is harmless: we only care whether count > 0.
  show_cmds := ARRAY_CONSTRUCT(
      'OBJECTS',            -- tables and views
      'DYNAMIC TABLES',
      'SERVICES',           -- SPCS services
      'NOTEBOOKS',
      'STREAMLITS',
      'STAGES',
      'USER FUNCTIONS',
      'USER PROCEDURES',
      'TASKS',
      'STREAMS',
      'PIPES',
      'SEQUENCES',
      'FILE FORMATS',
      'SECRETS',
      'ALERTS',
      'MODELS');
  n_cmds := ARRAY_SIZE(show_cmds);

  CREATE OR REPLACE TEMPORARY TABLE dropped_db_inventory (
      database_name STRING,
      object_type   STRING,
      object_count  INTEGER,
      error_msg     STRING
  );

  SHOW DATABASES LIKE 'DROPPED%';
  dbs := (SELECT "name" AS db_name
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
           WHERE STARTSWITH(UPPER("name"), :prefix));

  LET c1 CURSOR FOR dbs;
  FOR rec IN c1 DO
    db_name  := rec.db_name;
    db_ident := '"' || REPLACE(db_name, '"', '""') || '"';   -- names like USER$X need quoting

    -- Count objects of each type in every schema EXCEPT INFORMATION_SCHEMA
    -- (PUBLIC, LOCAL and any user-created schema are all included).
    FOR i IN 0 TO n_cmds - 1 DO
      obj_type := GET(show_cmds, i)::STRING;
      BEGIN
        EXECUTE IMMEDIATE 'SHOW ' || obj_type || ' IN DATABASE ' || db_ident;
        SELECT COUNT(*) INTO :cnt
          FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
         WHERE UPPER("schema_name") <> 'INFORMATION_SCHEMA';
        INSERT INTO dropped_db_inventory VALUES (:db_name, :obj_type, :cnt, NULL);
      EXCEPTION
        WHEN OTHER THEN
          err := SQLERRM;
          INSERT INTO dropped_db_inventory VALUES (:db_name, :obj_type, NULL, :err);
      END;
    END FOR;
  END FOR;

  result_rs := (
    SELECT database_name,
           COALESCE(SUM(object_count), 0)                              AS total_objects,
           LISTAGG(IFF(object_count > 0,
                       object_type || '=' || object_count, NULL), ', ')
             WITHIN GROUP (ORDER BY object_type)                       AS objects_found,
           LISTAGG(IFF(error_msg IS NOT NULL, object_type, NULL), ', ')
             WITHIN GROUP (ORDER BY object_type)                       AS checks_failed,
           (COALESCE(SUM(object_count), 0) = 0
             AND COUNT_IF(error_msg IS NOT NULL) = 0)                  AS safe_to_drop,
           IFF(COALESCE(SUM(object_count), 0) = 0
                 AND COUNT_IF(error_msg IS NOT NULL) = 0,
               'DROP DATABASE "' || REPLACE(database_name, '"', '""') || '";',
               NULL)                                                   AS drop_statement
      FROM dropped_db_inventory
     GROUP BY database_name
     ORDER BY safe_to_drop DESC, database_name
  );
  RETURN TABLE(result_rs);
END;
$$;

-- Drill-down (same session):
-- SELECT * FROM dropped_db_inventory WHERE object_count > 0 OR error_msg IS NOT NULL ORDER BY 1, 2;
