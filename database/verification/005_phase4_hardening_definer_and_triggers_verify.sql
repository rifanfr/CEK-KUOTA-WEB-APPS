-- =============================================================================
-- VERIFICATION QUERIES: MIGRATION 005 (READ-ONLY)
-- =============================================================================
SELECT n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) AS args,
       pg_catalog.pg_get_userbyid(p.proowner) AS owner, p.prosecdef, p.proconfig, p.proacl::text,
       pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE') AS pub_exec,
       pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
       pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec,
       pg_catalog.has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc_exec
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('public', 'private_internal')
ORDER BY n.nspname, p.proname;

SELECT c.relname AS tbl, t.tgname, t.tgenabled, t.tgdeferrable, t.tginitdeferred
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;
