-- =============================================================================
-- VERIFICATION QUERIES: MIGRATION 006 (READ-ONLY)
-- =============================================================================
SELECT n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity, c.relacl::text
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname IN ('kiosk_tokens', 'kiosk_rate_limits');

SELECT p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) AS args,
       p.prosecdef, p.proconfig, p.proacl::text,
       pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE') AS pub_exec,
       pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
       pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec,
       pg_catalog.has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc_exec
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'get_operational_snapshot_page_v4', 'get_operational_sync_data_v4',
    'prune_operational_change_feed_v4', 'verify_customer_registration_v4',
    'issue_kiosk_token', 'revoke_kiosk_token', 'get_public_kiosk_quota',
    'report_offline_reconciliation_conflict'
  )
ORDER BY p.proname;
