-- =============================================================================
-- ROLLBACK 006: NON-DESTRUCTIVE ROLLBACK OF EXPAND RPCs (PRESERVES KIOSK TOKENS)
-- Never drops populated public.kiosk_tokens or public.kiosk_rate_limits
-- =============================================================================
DROP FUNCTION IF EXISTS public.report_offline_reconciliation_conflict(TEXT, TEXT, INT, INT, TEXT, TIMESTAMPTZ, JSONB);
DROP FUNCTION IF EXISTS public.get_public_kiosk_quota(TEXT);
DROP FUNCTION IF EXISTS public.revoke_kiosk_token(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.issue_kiosk_token(TEXT, INT);
DROP FUNCTION IF EXISTS public.verify_customer_registration_v4(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.prune_operational_change_feed_v4(INTERVAL, INT, INT);
DROP FUNCTION IF EXISTS public.get_operational_sync_data_v4(BIGINT, INT, BIGINT);
DROP FUNCTION IF EXISTS public.get_operational_snapshot_page_v4(TEXT, TEXT, BIGINT, INT, BIGINT, DATE);

DO $$
DECLARE
  v_tok_cnt BIGINT := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='kiosk_tokens') THEN
    SELECT count(*) INTO v_tok_cnt FROM public.kiosk_tokens;
  END IF;
  IF v_tok_cnt > 0 THEN
    COMMENT ON TABLE public.kiosk_tokens IS 'DORMANT: Preserved citizen QR token hashes after 006 rollback';
    COMMENT ON TABLE public.kiosk_rate_limits IS 'DORMANT: Preserved after 006 rollback';
  ELSE
    DROP TABLE IF EXISTS public.kiosk_rate_limits;
    DROP TABLE IF EXISTS public.kiosk_tokens;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
