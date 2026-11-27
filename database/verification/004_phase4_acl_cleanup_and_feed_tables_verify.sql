-- =============================================================================
-- VERIFICATION QUERIES: MIGRATION 004 (READ-ONLY)
-- =============================================================================
SELECT pg_catalog.current_database() AS db_name, CURRENT_USER AS role_name;

SELECT pg_catalog.pg_get_userbyid(d.defaclrole) AS defacl_role, n.nspname AS schema_name, d.defaclobjtype, d.defaclacl::text
FROM pg_catalog.pg_default_acl d
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
WHERE d.defaclrole = 'postgres'::pg_catalog.regrole AND n.nspname IN ('public', 'private_internal')
ORDER BY n.nspname, d.defaclobjtype;

SELECT n.nspname, c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner,
       c.relrowsecurity, c.relforcerowsecurity, c.relacl::text
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public', 'private_internal') AND c.relkind IN ('r', 'p', 'S')
ORDER BY n.nspname, c.relname;

SELECT singleton_id, last_committed_seq, min_retained_seq, feed_epoch, last_pruned_at
FROM public.change_feed_tracker;
