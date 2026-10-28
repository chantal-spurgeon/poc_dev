/*
  find_unused_roles.sql

  Purpose : Identify account roles that look unused, classified by how strong
            the evidence is:

              ORPHAN          - not granted to any user or any other role
              NO ACTIVE USERS - granted somewhere, but no path through the role
                                hierarchy reaches an active (not dropped, not
                                disabled) user
              IDLE            - reaches active users, but neither this role nor
                                any role that inherits it was used as a primary
                                role in the last N days
              POSSIBLY VIA PARENT - not used directly in N days, but a role that
                                inherits it was, so its privileges may be in use

  Run as  : A role with access to SNOWFLAKE.ACCOUNT_USAGE (e.g. ACCOUNTADMIN).

  Notes   : - ACCOUNT_USAGE has latency (up to ~2 hours for grants), so very
              recent changes may not show yet.
            - QUERY_HISTORY records only the PRIMARY role of each query. Use of
              a role via secondary roles (USE SECONDARY ROLES ALL) is not
              visible here, so treat IDLE as "review", not "proof".
            - Roles managed by SCIM (Okta/Entra) should be removed at the IdP,
              not dropped here, or they may be re-provisioned. Check the owner.
            - When a role is dropped, objects it owns transfer to the role that
              runs DROP ROLE. Drop statements are only generated for roles that
              own nothing. Nothing is executed.
*/

SET lookback_days = 90;

WITH
roles AS (
    SELECT name AS role_name, owner, created_on, comment
      FROM snowflake.account_usage.roles
     WHERE deleted_on IS NULL
       AND role_type = 'ROLE'                                   -- account roles only
       AND name NOT IN ('ACCOUNTADMIN','SECURITYADMIN','SYSADMIN',
                        'USERADMIN','ORGADMIN','GLOBALORGADMIN','PUBLIC')
),
active_users AS (
    SELECT name AS user_name, default_role
      FROM snowflake.account_usage.users
     WHERE deleted_on IS NULL
       AND COALESCE(disabled::BOOLEAN, FALSE) = FALSE
),
user_grants AS (
    SELECT g.role AS role_name,
           g.grantee_name AS user_name,
           (a.user_name IS NOT NULL) AS is_active_user
      FROM snowflake.account_usage.grants_to_users g
      LEFT JOIN active_users a ON a.user_name = g.grantee_name
     WHERE g.deleted_on IS NULL
),
-- Role hierarchy: child role is granted to parent role
edges AS (
    SELECT name AS child_role, grantee_name AS parent_role
      FROM snowflake.account_usage.grants_to_roles
     WHERE deleted_on IS NULL
       AND granted_on = 'ROLE'
       AND granted_to = 'ROLE'
       AND privilege  = 'USAGE'
),
-- Roles reachable from an active user (directly or by inheritance)
reachable (role_name) AS (
    SELECT DISTINCT role_name FROM user_grants WHERE is_active_user
    UNION ALL
    SELECT e.child_role
      FROM reachable r
      JOIN edges e ON e.parent_role = r.role_name
),
reachable_distinct AS (SELECT DISTINCT role_name FROM reachable),
-- Every role that inherits a given role (all ancestors)
ancestors (role_name, ancestor) AS (
    SELECT child_role, parent_role FROM edges
    UNION ALL
    SELECT a.role_name, e.parent_role
      FROM ancestors a
      JOIN edges e ON e.child_role = a.ancestor
),
usage AS (
    SELECT role_name, MAX(start_time) AS last_used_as_primary
      FROM snowflake.account_usage.query_history
     WHERE start_time >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
     GROUP BY role_name
),
ancestor_used AS (
    SELECT DISTINCT a.role_name
      FROM ancestors a
      JOIN usage u ON u.role_name = a.ancestor
),
privs AS (
    SELECT grantee_name AS role_name,
           COUNT_IF(privilege = 'OWNERSHIP')                         AS owned_objects,
           COUNT_IF(privilege <> 'OWNERSHIP' AND granted_on <> 'ROLE') AS privileges_held
      FROM snowflake.account_usage.grants_to_roles
     WHERE deleted_on IS NULL
       AND granted_to = 'ROLE'
     GROUP BY grantee_name
),
summary AS (
    SELECT r.role_name,
           r.owner,
           r.created_on,
           r.comment,
           (SELECT COUNT(*) FROM user_grants ug
             WHERE ug.role_name = r.role_name AND ug.is_active_user)        AS active_users_direct,
           (SELECT COUNT(*) FROM user_grants ug
             WHERE ug.role_name = r.role_name AND NOT ug.is_active_user)    AS inactive_users_direct,
           (SELECT COUNT(*) FROM edges e WHERE e.child_role  = r.role_name) AS parent_roles,
           (SELECT COUNT(*) FROM edges e WHERE e.parent_role = r.role_name) AS child_roles,
           (SELECT COUNT(*) FROM active_users au
             WHERE au.default_role = r.role_name)                           AS default_role_for_users,
           (rd.role_name IS NOT NULL)                                       AS reaches_active_user,
           u.last_used_as_primary,
           (au2.role_name IS NOT NULL)                                      AS inheriting_role_used,
           COALESCE(p.owned_objects, 0)                                     AS owned_objects,
           COALESCE(p.privileges_held, 0)                                   AS privileges_held
      FROM roles r
      LEFT JOIN reachable_distinct rd ON rd.role_name  = r.role_name
      LEFT JOIN usage u               ON u.role_name   = r.role_name
      LEFT JOIN ancestor_used au2     ON au2.role_name = r.role_name
      LEFT JOIN privs p               ON p.role_name   = r.role_name
),
classified AS (
    SELECT s.*,
           CASE
             WHEN active_users_direct = 0 AND inactive_users_direct = 0
                  AND parent_roles = 0                    THEN '1 ORPHAN'
             WHEN NOT reaches_active_user                 THEN '2 NO ACTIVE USERS'
             WHEN last_used_as_primary IS NULL
                  AND NOT inheriting_role_used            THEN '3 IDLE'
             WHEN last_used_as_primary IS NULL            THEN '4 POSSIBLY VIA PARENT'
             ELSE 'IN USE'
           END AS classification
      FROM summary s
)
SELECT classification,
       role_name,
       owner,
       created_on,
       active_users_direct,
       inactive_users_direct,
       parent_roles,
       child_roles,
       default_role_for_users,
       last_used_as_primary,
       owned_objects,
       privileges_held,
       comment,
       IFF(classification IN ('1 ORPHAN','2 NO ACTIVE USERS')
             AND owned_objects = 0
             AND default_role_for_users = 0,
           'DROP ROLE "' || REPLACE(role_name, '"', '""') || '";',
           NULL)                                                   AS drop_statement
  FROM classified
 WHERE classification <> 'IN USE'
 ORDER BY classification, role_name;
