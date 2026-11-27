-- =============================================================================
-- ROLLBACK 004: NON-DESTRUCTIVE ROLLBACK OF PHASE 4 FOUNDATIONS
-- Preserves Dxtm revocation (never re-grants TRUNCATE/TRIGGER/REFERENCES/MAINTAIN)
-- Never drops populated operational_change_feed / change_feed_tracker / conflicts
-- =============================================================================

DO $$
DECLARE
  v_feed_rows     BIGINT := 0;
  v_conflict_rows BIGINT := 0;
  v_hwm           BIGINT := 1;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='operational_change_feed') THEN
    SELECT count(*) INTO v_feed_rows FROM public.operational_change_feed;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='offline_reconciliation_conflicts') THEN
    SELECT count(*) INTO v_conflict_rows FROM public.offline_reconciliation_conflicts;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='change_feed_tracker') THEN
    SELECT COALESCE(max(last_committed_seq), 1) INTO v_hwm FROM public.change_feed_tracker;
  END IF;

  IF v_feed_rows > 0 OR v_conflict_rows > 0 OR v_hwm > 1 THEN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='operational_change_feed') THEN
      COMMENT ON TABLE public.operational_change_feed IS 'DORMANT: Preserved after Phase 4 rollback (non-destructive)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='change_feed_tracker') THEN
      COMMENT ON TABLE public.change_feed_tracker IS 'DORMANT: Preserved after Phase 4 rollback (non-destructive)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='offline_reconciliation_conflicts') THEN
      COMMENT ON TABLE public.offline_reconciliation_conflicts IS 'DORMANT: Preserved after Phase 4 rollback (non-destructive)';
    END IF;
  ELSE
    DROP TABLE IF EXISTS public.offline_reconciliation_conflicts;
    DROP TABLE IF EXISTS public.operational_change_feed;
    DROP TABLE IF EXISTS public.change_feed_tracker;
    DROP SCHEMA IF EXISTS private_internal;
  END IF;
END
$$;
