-- =============================================================================
-- ROLLBACK 005: DETACH PHASE 4 TRIGGERS WHILE PRESERVING HARDENED RPC ACLs
-- Never reverts functions back to weak search_path=public or proacl=null
-- Preserves transaction_audit_trail and operational_change_feed rows intact
-- =============================================================================
DROP TRIGGER IF EXISTS trg_cf_customers ON public.customers;
DROP TRIGGER IF EXISTS trg_cf_logs ON public.logs;
DROP TRIGGER IF EXISTS trg_cf_warehouse_logs ON public.warehouse_logs;
DROP TRIGGER IF EXISTS trg_audit_customers_track ON public.customers;

DROP FUNCTION IF EXISTS private_internal.trg_fn_capture_change_feed_v4();
DROP FUNCTION IF EXISTS private_internal.calculate_canonical_fingerprint_v2(
  pg_catalog.text, pg_catalog.text, pg_catalog.text, pg_catalog.jsonb
);
DROP FUNCTION IF EXISTS public.capture_customers_audit_trigger();
