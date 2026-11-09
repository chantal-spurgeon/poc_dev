-- granted directly

SELECT grantee_name AS user_name
FROM snowflake.account_usage.grants_to_users
WHERE role IN ('<role1>', '<role2>')
  AND deleted_on IS NULL
GROUP BY grantee_name
HAVING COUNT(DISTINCT role) = 2
ORDER BY user_name;

-- granted heiarchally

WITH RECURSIVE user_roles AS (
    -- roles granted straight to users
    SELECT grantee_name AS user_name,
           role         AS role_name,
           role         AS via_role,
           0            AS depth
    FROM snowflake.account_usage.grants_to_users
    WHERE deleted_on IS NULL
    UNION ALL
    -- roles those roles contain
    SELECT ur.user_name,
           g.name,
           ur.via_role,
           ur.depth + 1
    FROM user_roles ur
    JOIN snowflake.account_usage.grants_to_roles g
      ON g.grantee_name = ur.role_name
     AND g.granted_on   = 'ROLE'
     AND g.privilege    = 'USAGE'
     AND g.granted_to   = 'ROLE'
     AND g.deleted_on IS NULL
    WHERE ur.depth < 20
)
SELECT user_name,
       LISTAGG(DISTINCT role_name || ' (via ' || via_role || ')', ', ') AS how_held
FROM user_roles
WHERE role_name IN ('<role1>', '<role2>')
GROUP BY user_name
HAVING COUNT(DISTINCT role_name) = 2
ORDER BY user_name;
