-- =============================================================================
-- PHASE 4 MIGRATION 006: EXPAND READ, SYNC, PRUNE, VERIFY & KIOSK ZERO-PII RPCs
-- Project: Catat Kuota KK (Staging: evexaeyryfayfbffzzhh)
-- Baseline: Phase 4.2.2 Corrected Blueprint (F-04 Expand, F-05, C-04, C-06)
-- Preserves: Legacy "Staging read ..." policies & SELECT grants until 007 Contract
-- =============================================================================

-- 0. PRE-MIGRATION ASSERTIONS
DO $$
DECLARE
  v_bad_defacl INT;
BEGIN
  IF pg_catalog.current_database() <> 'postgres' OR CURRENT_USER <> 'postgres' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: expected database postgres as user postgres';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'private_internal') OR
     NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = 'change_feed_tracker') THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: migration 004 foundations missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'customers' AND t.tgname = 'trg_cf_customers' AND t.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: migration 005 triggers missing';
  END IF;

  SELECT count(*) INTO v_bad_defacl
  FROM pg_catalog.pg_default_acl d
  LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) AS a
  WHERE d.defaclrole = 'postgres'::pg_catalog.regrole
    AND n.nspname IN ('public', 'private_internal')
    AND a.grantee IN (
      0::pg_catalog.oid,
      'anon'::pg_catalog.regrole,
      'authenticated'::pg_catalog.regrole,
      'service_role'::pg_catalog.regrole
    );
  IF v_bad_defacl > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: pg_default_acl regression detected before 006 tables';
  END IF;
END
$$;


-- =============================================================================
-- 1. CATEGORY 4 TABLES: KIOSK TOKENS & RATE LIMITS (0 DIRECT ACCESS)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.kiosk_tokens (
  token_hash       TEXT PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  no_kk            TEXT NOT NULL CHECK (no_kk ~ '^[0-9]{16}$'),
  status           TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REPLACED', 'REVOKED', 'EXPIRED')),
  replaced_by_hash TEXT CHECK (replaced_by_hash IS NULL OR replaced_by_hash ~ '^[0-9a-f]{64}$'),
  issued_by        TEXT NOT NULL,
  issued_at        TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  expires_at       TIMESTAMPTZ,
  revoked_by       TEXT,
  revoked_at       TIMESTAMPTZ,
  revoke_reason    TEXT
);

CREATE INDEX IF NOT EXISTS idx_kiosk_tokens_nokk_status
  ON public.kiosk_tokens (no_kk, status, issued_at DESC);

ALTER TABLE public.kiosk_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.kiosk_tokens FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.kiosk_tokens IS
  'SHA-256 digests of public citizen kiosk QR tokens; accessed exclusively via SECURITY DEFINER RPCs.';

CREATE TABLE IF NOT EXISTS public.kiosk_rate_limits (
  bucket_key        TEXT PRIMARY KEY,
  window_started_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  hit_count         INT NOT NULL DEFAULT 1 CHECK (hit_count >= 1)
);

CREATE INDEX IF NOT EXISTS idx_kiosk_rl_window
  ON public.kiosk_rate_limits (window_started_at);

ALTER TABLE public.kiosk_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.kiosk_rate_limits FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.kiosk_rate_limits IS
  'Server-side rate limiting buckets for anonymous public kiosk requests.';


-- =============================================================================
-- 2. RPC 1: KEYSET SNAPSHOT PAGINATION (FROZEN CUTOFF & SINGLE-STMT MVCC PAGE 1)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_operational_snapshot_page_v4(
  p_section              TEXT,
  p_after_pk             TEXT DEFAULT NULL,
  p_snapshot_anchor_seq  BIGINT DEFAULT NULL,
  p_page_limit           INT DEFAULT 500,
  p_client_feed_epoch    BIGINT DEFAULT NULL,
  p_snapshot_cutoff_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims       pg_catalog.text;
  v_jwt_claims       pg_catalog.jsonb;
  v_jwt_role         pg_catalog.text;
  v_app_role         pg_catalog.text;
  v_clean_section    pg_catalog.text;
  v_limit            pg_catalog.int4;
  v_after            pg_catalog.text;
  v_is_page1         pg_catalog.bool;
  v_hwm              pg_catalog.int8;
  v_min_retained     pg_catalog.int8;
  v_epoch            pg_catalog.int8;
  v_anchor           pg_catalog.int8;
  v_cutoff_date      pg_catalog.date;
  v_rows             pg_catalog.jsonb := '[]'::pg_catalog.jsonb;
  v_next_after_pk    pg_catalog.text := NULL;
  v_probe_count      pg_catalog.int4 := 0;
  v_has_more         pg_catalog.bool := false;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  v_clean_section := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_section, '')));

  IF v_app_role = 'cashier' THEN
    -- Conservative Owner Decision #1 default: cashier reads customers & logs only (zero raw warehouse_logs / stock_summary)
    IF v_clean_section NOT IN ('customers', 'logs') THEN
      RAISE EXCEPTION 'FORBIDDEN: Role cashier unauthorized for section "%"', v_clean_section USING ERRCODE = '42501';
    END IF;
  ELSIF v_app_role = 'warehouse_admin' THEN
    IF v_clean_section NOT IN ('warehouse_logs', 'stock_summary') THEN
      RAISE EXCEPTION 'FORBIDDEN: Role warehouse_admin unauthorized for section "%"', v_clean_section USING ERRCODE = '42501';
    END IF;
  ELSIF v_app_role IN ('supervisor', 'admin') THEN
    IF v_clean_section NOT IN ('customers', 'logs', 'warehouse_logs', 'stock_summary') THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: Unknown snapshot section "%"', v_clean_section USING ERRCODE = 'P0006';
    END IF;
  ELSE
    RAISE EXCEPTION 'FORBIDDEN: Unauthorized role "%"', v_app_role USING ERRCODE = '42501';
  END IF;

  v_limit   := LEAST(GREATEST(COALESCE(p_page_limit, 500), 1), 500);
  v_after   := COALESCE(p_after_pk, '');
  v_is_page1 := (p_snapshot_anchor_seq IS NULL);

  IF NOT v_is_page1 THEN
    IF p_client_feed_epoch IS NULL OR p_snapshot_cutoff_date IS NULL THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: Continuation snapshot pages require p_client_feed_epoch and p_snapshot_cutoff_date'
        USING ERRCODE = 'P0006';
    END IF;

    SELECT t.last_committed_seq, t.min_retained_seq, t.feed_epoch
    INTO v_hwm, v_min_retained, v_epoch
    FROM public.change_feed_tracker t
    WHERE t.singleton_id = 1;

    IF p_client_feed_epoch IS DISTINCT FROM v_epoch THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'EPOCH_MISMATCH',
        'section', v_clean_section,
        'snapshot_anchor_seq', p_snapshot_anchor_seq,
        'snapshot_cutoff_date', p_snapshot_cutoff_date,
        'min_retained_seq', v_min_retained,
        'current_hwm', v_hwm,
        'feed_epoch', v_epoch,
        'action_required', 'RESTART_SNAPSHOT'
      );
    END IF;

    IF p_snapshot_anchor_seq < (v_min_retained - 1) OR p_snapshot_anchor_seq > v_hwm THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'SNAPSHOT_EXPIRED',
        'section', v_clean_section,
        'snapshot_anchor_seq', p_snapshot_anchor_seq,
        'snapshot_cutoff_date', p_snapshot_cutoff_date,
        'min_retained_seq', v_min_retained,
        'current_hwm', v_hwm,
        'feed_epoch', v_epoch,
        'action_required', 'RESTART_SNAPSHOT'
      );
    END IF;
  END IF;

  -- Single-statement MVCC execution pairing tracker metadata & keyset page
  IF v_clean_section = 'customers' THEN
    WITH tracker AS (
      SELECT last_committed_seq, min_retained_seq, feed_epoch,
             ((pg_catalog.timezone('Asia/Jakarta', pg_catalog.clock_timestamp()))::pg_catalog.date - 35) AS computed_cutoff
      FROM public.change_feed_tracker
      WHERE singleton_id = 1
    ),
    probe AS (
      SELECT c.no_kk AS pk,
             pg_catalog.jsonb_build_object(
               'no_kk', c.no_kk,
               'member_id', c.member_id,
               'nama', c.nama,
               'provinsi', c.provinsi,
               'kabupaten', c.kabupaten,
               'kecamatan', c.kecamatan,
               'desa', c.desa,
               'detail', c.detail,
               'created_at', c.created_at
             ) AS payload
      FROM public.customers c
      WHERE c.no_kk > v_after
      ORDER BY c.no_kk ASC
      LIMIT v_limit + 1
    ),
    ranked AS (
      SELECT pk, payload, pg_catalog.row_number() OVER (ORDER BY pk ASC) AS rn
      FROM probe
    )
    SELECT
      tr.last_committed_seq,
      tr.min_retained_seq,
      tr.feed_epoch,
      CASE WHEN v_is_page1 THEN tr.last_committed_seq ELSE p_snapshot_anchor_seq END,
      CASE WHEN v_is_page1 THEN tr.computed_cutoff ELSE p_snapshot_cutoff_date END,
      (SELECT pg_catalog.count(*)::pg_catalog.int4 FROM ranked),
      COALESCE((SELECT pg_catalog.jsonb_agg(r.payload ORDER BY r.pk ASC) FROM ranked r WHERE r.rn <= v_limit), '[]'::pg_catalog.jsonb),
      (SELECT MAX(r.pk) FROM ranked r WHERE r.rn <= v_limit)
    INTO v_hwm, v_min_retained, v_epoch, v_anchor, v_cutoff_date, v_probe_count, v_rows, v_next_after_pk
    FROM tracker tr;

  ELSIF v_clean_section = 'logs' THEN
    WITH tracker AS (
      SELECT last_committed_seq, min_retained_seq, feed_epoch,
             ((pg_catalog.timezone('Asia/Jakarta', pg_catalog.clock_timestamp()))::pg_catalog.date - 35) AS computed_cutoff
      FROM public.change_feed_tracker
      WHERE singleton_id = 1
    ),
    eff AS (
      SELECT last_committed_seq, min_retained_seq, feed_epoch,
             CASE WHEN v_is_page1 THEN computed_cutoff ELSE p_snapshot_cutoff_date END AS eff_cutoff
      FROM tracker
    ),
    probe AS (
      SELECT l.id AS pk,
             pg_catalog.jsonb_build_object(
               'id', l.id,
               'request_id', l.request_id,
               'operator_id', l.operator_id,
               'date', l.date,
               'time', l.time,
               'member_id', l.member_id,
               'nama', l.nama,
               'no_kk', l.no_kk,
               'qty_beras', l.qty_beras,
               'qty_gas', l.qty_gas,
               'total_pcs', l.total_pcs,
               'status', l.status,
               'revisi_note', l.revisi_note,
               'created_at', l.created_at
             ) AS payload
      FROM public.logs l
      CROSS JOIN eff e
      WHERE l.date >= e.eff_cutoff
        AND l.id > v_after
      ORDER BY l.id ASC
      LIMIT v_limit + 1
    ),
    ranked AS (
      SELECT pk, payload, pg_catalog.row_number() OVER (ORDER BY pk ASC) AS rn
      FROM probe
    )
    SELECT
      e.last_committed_seq,
      e.min_retained_seq,
      e.feed_epoch,
      CASE WHEN v_is_page1 THEN e.last_committed_seq ELSE p_snapshot_anchor_seq END,
      e.eff_cutoff,
      (SELECT pg_catalog.count(*)::pg_catalog.int4 FROM ranked),
      COALESCE((SELECT pg_catalog.jsonb_agg(r.payload ORDER BY r.pk ASC) FROM ranked r WHERE r.rn <= v_limit), '[]'::pg_catalog.jsonb),
      (SELECT MAX(r.pk) FROM ranked r WHERE r.rn <= v_limit)
    INTO v_hwm, v_min_retained, v_epoch, v_anchor, v_cutoff_date, v_probe_count, v_rows, v_next_after_pk
    FROM eff e;

  ELSIF v_clean_section = 'warehouse_logs' THEN
    WITH tracker AS (
      SELECT last_committed_seq, min_retained_seq, feed_epoch,
             ((pg_catalog.timezone('Asia/Jakarta', pg_catalog.clock_timestamp()))::pg_catalog.date - 35) AS computed_cutoff
      FROM public.change_feed_tracker
      WHERE singleton_id = 1
    ),
    probe AS (
      SELECT w.id AS pk,
             pg_catalog.jsonb_build_object(
               'id', w.id,
               'request_id', w.request_id,
               'date', w.date,
               'type', w.type,
               'item', w.item,
               'qty', w.qty,
               'ref', w.ref,
               'log_id', w.log_id,
               'is_void', w.is_void,
               'created_at', w.created_at
             ) AS payload
      FROM public.warehouse_logs w
      WHERE w.id > v_after
      ORDER BY w.id ASC
      LIMIT v_limit + 1
    ),
    ranked AS (
      SELECT pk, payload, pg_catalog.row_number() OVER (ORDER BY pk ASC) AS rn
      FROM probe
    )
    SELECT
      tr.last_committed_seq,
      tr.min_retained_seq,
      tr.feed_epoch,
      CASE WHEN v_is_page1 THEN tr.last_committed_seq ELSE p_snapshot_anchor_seq END,
      CASE WHEN v_is_page1 THEN tr.computed_cutoff ELSE p_snapshot_cutoff_date END,
      (SELECT pg_catalog.count(*)::pg_catalog.int4 FROM ranked),
      COALESCE((SELECT pg_catalog.jsonb_agg(r.payload ORDER BY r.pk ASC) FROM ranked r WHERE r.rn <= v_limit), '[]'::pg_catalog.jsonb),
      (SELECT MAX(r.pk) FROM ranked r WHERE r.rn <= v_limit)
    INTO v_hwm, v_min_retained, v_epoch, v_anchor, v_cutoff_date, v_probe_count, v_rows, v_next_after_pk
    FROM tracker tr;

  ELSIF v_clean_section = 'stock_summary' THEN
    WITH tracker AS (
      SELECT last_committed_seq, min_retained_seq, feed_epoch,
             ((pg_catalog.timezone('Asia/Jakarta', pg_catalog.clock_timestamp()))::pg_catalog.date - 35) AS computed_cutoff
      FROM public.change_feed_tracker
      WHERE singleton_id = 1
    ),
    per_item AS (
      SELECT w.item,
             COALESCE(SUM(
               CASE
                 WHEN w.type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN w.qty
                 WHEN w.type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -w.qty
                 ELSE 0
               END
             ), 0)::pg_catalog.int4 AS available
      FROM public.warehouse_logs w
      WHERE w.is_void IS NOT TRUE
      GROUP BY w.item
    )
    SELECT
      tr.last_committed_seq,
      tr.min_retained_seq,
      tr.feed_epoch,
      CASE WHEN v_is_page1 THEN tr.last_committed_seq ELSE p_snapshot_anchor_seq END,
      CASE WHEN v_is_page1 THEN tr.computed_cutoff ELSE p_snapshot_cutoff_date END,
      0,
      COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item', p.item, 'available', p.available) ORDER BY p.item) FROM per_item p), '[]'::pg_catalog.jsonb),
      NULL
    INTO v_hwm, v_min_retained, v_epoch, v_anchor, v_cutoff_date, v_probe_count, v_rows, v_next_after_pk
    FROM tracker tr;
  END IF;

  v_has_more := (v_probe_count > v_limit);

  RETURN pg_catalog.jsonb_build_object(
    'status', 'OK',
    'section', v_clean_section,
    'snapshot_anchor_seq', v_anchor,
    'snapshot_cutoff_date', v_cutoff_date,
    'min_retained_seq', v_min_retained,
    'current_hwm', v_hwm,
    'feed_epoch', v_epoch,
    'rows', v_rows,
    'next_after_pk', CASE WHEN v_has_more THEN v_next_after_pk ELSE NULL END,
    'has_more', v_has_more
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_operational_snapshot_page_v4(
  TEXT, TEXT, BIGINT, INT, BIGINT, DATE
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_operational_snapshot_page_v4(
  TEXT, TEXT, BIGINT, INT, BIGINT, DATE
) TO postgres, authenticated;


-- =============================================================================
-- 3. RPC 2: DELTA SYNC WITH ROLE FILTERING, N+1 PROBE & SAFE CURSOR ADVANCEMENT
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_operational_sync_data_v4(
  p_since_seq         BIGINT,
  p_scan_limit        INT DEFAULT 500,
  p_client_feed_epoch BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims       pg_catalog.text;
  v_jwt_claims       pg_catalog.jsonb;
  v_jwt_role         pg_catalog.text;
  v_app_role         pg_catalog.text;
  v_allowed_tables   pg_catalog.text[];
  v_limit            pg_catalog.int4;
  v_hwm              pg_catalog.int8;
  v_min_retained     pg_catalog.int8;
  v_epoch            pg_catalog.int8;
  v_probe_count      pg_catalog.int4 := 0;
  v_has_more         pg_catalog.bool := false;
  v_last_scanned     pg_catalog.int8 := NULL;
  v_last_returned    pg_catalog.int8 := NULL;
  v_next_cursor      pg_catalog.int8;
  v_changes          pg_catalog.jsonb := '[]'::pg_catalog.jsonb;
  v_stock_summary    pg_catalog.jsonb := NULL;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role = 'cashier' THEN
    v_allowed_tables := ARRAY['customers', 'logs'];
  ELSIF v_app_role = 'warehouse_admin' THEN
    v_allowed_tables := ARRAY['warehouse_logs'];
  ELSIF v_app_role IN ('supervisor', 'admin') THEN
    v_allowed_tables := ARRAY['customers', 'logs', 'warehouse_logs'];
  ELSE
    RAISE EXCEPTION 'FORBIDDEN: Unauthorized role "%"', v_app_role USING ERRCODE = '42501';
  END IF;

  IF p_since_seq IS NULL OR p_since_seq < 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_since_seq must be a non-negative integer' USING ERRCODE = 'P0006';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_scan_limit, 500), 1), 1000);

  -- Single-statement MVCC read of tracker + bounded change feed + optional stock summary
  WITH tracker AS (
    SELECT t.last_committed_seq, t.min_retained_seq, t.feed_epoch
    FROM public.change_feed_tracker t
    WHERE t.singleton_id = 1
  ),
  probe AS (
    SELECT f.change_seq, f.table_name, f.record_id, f.action_type, f.record_data, f.recorded_at,
           pg_catalog.row_number() OVER (ORDER BY f.change_seq ASC) AS rn
    FROM public.operational_change_feed f
    CROSS JOIN tracker t
    WHERE p_since_seq <= t.last_committed_seq
      AND p_since_seq >= (t.min_retained_seq - 1)
      AND (p_client_feed_epoch IS NULL OR p_client_feed_epoch = t.feed_epoch)
      AND f.change_seq > p_since_seq
      AND f.change_seq <= t.last_committed_seq
    ORDER BY f.change_seq ASC
    LIMIT v_limit + 1
  ),
  bounded AS (
    SELECT * FROM probe WHERE rn <= v_limit
  ),
  stock_items AS (
    SELECT w.item,
           COALESCE(SUM(
             CASE
               WHEN w.type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN w.qty
               WHEN w.type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -w.qty
               ELSE 0
             END
           ), 0)::pg_catalog.int4 AS available
    FROM public.warehouse_logs w
    WHERE v_app_role IN ('warehouse_admin', 'supervisor', 'admin')
      AND w.is_void IS NOT TRUE
    GROUP BY w.item
  )
  SELECT
    t.last_committed_seq,
    t.min_retained_seq,
    t.feed_epoch,
    (SELECT pg_catalog.count(*)::pg_catalog.int4 FROM probe),
    (SELECT MAX(b.change_seq) FROM bounded b),
    (SELECT MAX(b.change_seq) FROM bounded b WHERE b.table_name = ANY(v_allowed_tables)),
    COALESCE(
      (SELECT pg_catalog.jsonb_agg(
         pg_catalog.jsonb_build_object(
           'change_seq', b.change_seq,
           'table_name', b.table_name,
           'record_id', b.record_id,
           'action_type', b.action_type,
           'record_data', b.record_data,
           'recorded_at', b.recorded_at
         ) ORDER BY b.change_seq ASC
       )
       FROM bounded b
       WHERE b.table_name = ANY(v_allowed_tables)),
      '[]'::pg_catalog.jsonb
    ),
    CASE WHEN v_app_role IN ('warehouse_admin', 'supervisor', 'admin') THEN
      COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item', s.item, 'available', s.available) ORDER BY s.item) FROM stock_items s), '[]'::pg_catalog.jsonb)
    ELSE NULL END
  INTO v_hwm, v_min_retained, v_epoch, v_probe_count, v_last_scanned, v_last_returned, v_changes, v_stock_summary
  FROM tracker t;

  IF p_client_feed_epoch IS NOT NULL AND p_client_feed_epoch IS DISTINCT FROM v_epoch THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'EPOCH_MISMATCH',
      'client_seq', p_since_seq,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_hwm,
      'feed_epoch', v_epoch,
      'action_required', 'FULL_SNAPSHOT'
    );
  END IF;

  IF p_since_seq > v_hwm THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'CURSOR_AHEAD_OF_HWM',
      'client_seq', p_since_seq,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_hwm,
      'feed_epoch', v_epoch,
      'action_required', 'FULL_SNAPSHOT'
    );
  END IF;

  IF p_since_seq < (v_min_retained - 1) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'CURSOR_EXPIRED',
      'client_seq', p_since_seq,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_hwm,
      'feed_epoch', v_epoch,
      'action_required', 'FULL_SNAPSHOT'
    );
  END IF;

  v_has_more     := (v_probe_count > v_limit);
  v_last_scanned := COALESCE(v_last_scanned, p_since_seq);
  v_next_cursor  := CASE WHEN v_has_more THEN v_last_scanned ELSE v_hwm END;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'OK',
    'changes', v_changes,
    'stock_summary', v_stock_summary,
    'last_scanned_seq', v_last_scanned,
    'last_returned_seq', v_last_returned,
    'next_cursor', v_next_cursor,
    'current_hwm', v_hwm,
    'min_retained_seq', v_min_retained,
    'feed_epoch', v_epoch,
    'has_more', v_has_more
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_operational_sync_data_v4(
  BIGINT, INT, BIGINT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_operational_sync_data_v4(
  BIGINT, INT, BIGINT
) TO postgres, authenticated;


-- =============================================================================
-- 4. RPC 3: CONTIGUOUS PREFIX PRUNING (C-01 AUTH + C-06 BATCHED BOUNDARY)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.prune_operational_change_feed_v4(
  p_retention_interval INTERVAL DEFAULT INTERVAL '30 days',
  p_safety_buffer      INT DEFAULT 5000,
  p_batch_limit        INT DEFAULT 5000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims       pg_catalog.text;
  v_claims           pg_catalog.jsonb;
  v_claim_role       pg_catalog.text;
  v_jwt_role         pg_catalog.text;
  v_current_hwm      pg_catalog.int8;
  v_min_retained     pg_catalog.int8;
  v_cutoff           pg_catalog.timestamptz;
  v_buffer_ceiling   pg_catalog.int8;
  v_first_kept_seq   pg_catalog.int8;
  v_del_ceiling      pg_catalog.int8;
  v_batch_max_seq    pg_catalog.int8;
  v_rows_deleted     pg_catalog.int4 := 0;
  v_max_deleted_seq  pg_catalog.int8;
  v_new_min_retained pg_catalog.int8;
  v_has_more_prune   pg_catalog.bool := false;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_claims     := v_raw_claims::pg_catalog.jsonb;
  v_claim_role := NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), '');
  v_jwt_role   := COALESCE(v_claim_role, v_claims ->> 'role', '');

  -- Strictly verify SESSION_USER (NEVER CURRENT_USER inside SECURITY DEFINER)
  IF NOT (
    (SESSION_USER = 'authenticator' AND v_jwt_role = 'service_role')
    OR
    (SESSION_USER IN ('postgres', 'supabase_admin') AND v_raw_claims IS NULL AND v_claim_role IS NULL)
  ) THEN
    RAISE EXCEPTION 'FORBIDDEN: Pruning authorized solely for PostgREST service_role or DBA session'
      USING ERRCODE = '42501';
  END IF;

  IF p_retention_interval IS NULL OR p_retention_interval < INTERVAL '1 day' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_retention_interval must be >= 1 day' USING ERRCODE = 'P0006';
  END IF;

  IF p_safety_buffer IS NULL OR p_safety_buffer < 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_safety_buffer must be >= 0' USING ERRCODE = 'P0006';
  END IF;

  IF p_batch_limit IS NULL OR p_batch_limit < 1 OR p_batch_limit > 10000 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_batch_limit must be between 1 and 10000' USING ERRCODE = 'P0006';
  END IF;

  -- Lock tracker row first (Level 4)
  SELECT t.last_committed_seq, t.min_retained_seq
  INTO v_current_hwm, v_min_retained
  FROM public.change_feed_tracker t
  WHERE t.singleton_id = 1
  FOR UPDATE;

  v_cutoff         := pg_catalog.clock_timestamp() - p_retention_interval;
  v_buffer_ceiling := v_current_hwm - p_safety_buffer;

  IF v_buffer_ceiling < v_min_retained THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'OK',
      'rows_deleted', 0,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_current_hwm,
      'has_more_to_prune', false
    );
  END IF;

  SELECT MIN(f.change_seq)
  INTO v_first_kept_seq
  FROM public.operational_change_feed f
  WHERE f.change_seq >= v_min_retained
    AND f.change_seq <= v_buffer_ceiling
    AND f.recorded_at >= v_cutoff;

  IF v_first_kept_seq IS NOT NULL THEN
    v_del_ceiling := v_first_kept_seq - 1;
  ELSE
    SELECT COALESCE(MAX(f.change_seq), v_min_retained - 1)
    INTO v_del_ceiling
    FROM public.operational_change_feed f
    WHERE f.change_seq >= v_min_retained
      AND f.change_seq <= v_buffer_ceiling;
  END IF;

  IF v_del_ceiling < v_min_retained THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'OK',
      'rows_deleted', 0,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_current_hwm,
      'has_more_to_prune', false
    );
  END IF;

  SELECT MAX(sub.change_seq)
  INTO v_batch_max_seq
  FROM (
    SELECT f.change_seq
    FROM public.operational_change_feed f
    WHERE f.change_seq >= v_min_retained
      AND f.change_seq <= v_del_ceiling
    ORDER BY f.change_seq ASC
    LIMIT p_batch_limit
  ) sub;

  IF v_batch_max_seq IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'OK',
      'rows_deleted', 0,
      'min_retained_seq', v_min_retained,
      'current_hwm', v_current_hwm,
      'has_more_to_prune', false
    );
  END IF;

  WITH deleted AS (
    DELETE FROM public.operational_change_feed f
    WHERE f.change_seq >= v_min_retained
      AND f.change_seq <= v_batch_max_seq
    RETURNING f.change_seq
  )
  SELECT pg_catalog.count(*)::pg_catalog.int4, MAX(d.change_seq)
  INTO v_rows_deleted, v_max_deleted_seq
  FROM deleted d;

  v_new_min_retained := GREATEST(v_min_retained, COALESCE(v_max_deleted_seq, v_min_retained - 1) + 1);
  v_has_more_prune   := (v_batch_max_seq < v_del_ceiling);

  UPDATE public.change_feed_tracker
  SET min_retained_seq = v_new_min_retained,
      last_pruned_at   = pg_catalog.clock_timestamp(),
      updated_at       = pg_catalog.clock_timestamp()
  WHERE singleton_id = 1;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'OK',
    'rows_deleted', v_rows_deleted,
    'min_retained_seq', v_new_min_retained,
    'current_hwm', v_current_hwm,
    'has_more_to_prune', v_has_more_prune
  );
END;
$$;

REVOKE ALL ON FUNCTION public.prune_operational_change_feed_v4(
  INTERVAL, INT, INT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prune_operational_change_feed_v4(
  INTERVAL, INT, INT
) TO postgres, service_role;


-- =============================================================================
-- 5. RPC 4: REGISTRATION TIMEOUT VERIFICATION (REPLACES DIRECT REST GET L12445)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.verify_customer_registration_v4(
  p_request_id TEXT,
  p_no_kk      TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims   pg_catalog.text;
  v_jwt_claims   pg_catalog.jsonb;
  v_jwt_role     pg_catalog.text;
  v_app_role     pg_catalog.text;
  v_clean_req_id pg_catalog.text;
  v_clean_no_kk  pg_catalog.text;
  v_req_row      RECORD;
  v_cust_row     RECORD;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Role "%" unauthorized for customer registration verification', v_app_role USING ERRCODE = '42501';
  END IF;

  v_clean_req_id := pg_catalog.btrim(COALESCE(p_request_id, ''));
  v_clean_no_kk  := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF v_clean_req_id = '' OR pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: valid p_request_id and 16-digit p_no_kk required' USING ERRCODE = 'P0006';
  END IF;

  SELECT request_id, customer_no_kk
  INTO v_req_row
  FROM public.customer_registration_requests
  WHERE request_id = v_clean_req_id;

  IF FOUND THEN
    IF v_req_row.customer_no_kk IS DISTINCT FROM v_clean_no_kk THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'IDEMPOTENCY_CONFLICT',
        'code', 'P0009',
        'message', 'request_id already committed for a different customer'
      );
    END IF;

    SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
    INTO v_cust_row
    FROM public.customers
    WHERE no_kk = v_req_row.customer_no_kk;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'COMMITTED_MATCH',
      'is_idempotent_replay', true,
      'customer', pg_catalog.to_jsonb(v_cust_row)
    );
  END IF;

  SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_cust_row
  FROM public.customers
  WHERE no_kk = v_clean_no_kk;

  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'EXISTS_IDENTITY_CHECK',
      'customer', pg_catalog.jsonb_build_object(
        'no_kk', v_cust_row.no_kk,
        'member_id', v_cust_row.member_id,
        'nama', v_cust_row.nama,
        'provinsi', v_cust_row.provinsi,
        'kabupaten', v_cust_row.kabupaten,
        'kecamatan', v_cust_row.kecamatan,
        'desa', v_cust_row.desa,
        'detail', v_cust_row.detail,
        'created_at', v_cust_row.created_at
      )
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object('status', 'NOT_FOUND');
END;
$$;

REVOKE ALL ON FUNCTION public.verify_customer_registration_v4(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_customer_registration_v4(TEXT, TEXT)
  TO postgres, authenticated;


-- =============================================================================
-- 6. RPCs 5-8: KIOSK TOKEN MANAGEMENT, ZERO-PII LOOKUP & CONFLICT ESCALATION
-- =============================================================================
CREATE OR REPLACE FUNCTION public.issue_kiosk_token(
  p_no_kk        TEXT,
  p_expires_days INT DEFAULT 365
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims  pg_catalog.text;
  v_jwt_claims  pg_catalog.jsonb;
  v_jwt_role    pg_catalog.text;
  v_app_role    pg_catalog.text;
  v_actor       pg_catalog.text;
  v_clean_no_kk pg_catalog.text;
  v_raw_token   pg_catalog.text;
  v_token_hash  pg_catalog.text;
  v_expires_at  pg_catalog.timestamptz := NULL;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  -- Conservative Owner Decision #4 default: supervisor/admin only
  IF v_app_role NOT IN ('supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Role "%" not permitted to issue kiosk tokens', v_app_role USING ERRCODE = '42501';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: 16-digit p_no_kk required' USING ERRCODE = 'P0006';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('KK:' || v_clean_no_kk, 0));

  IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.no_kk = v_clean_no_kk) THEN
    RAISE EXCEPTION 'NOT_FOUND: Customer KK % not registered', v_clean_no_kk USING ERRCODE = 'P0006';
  END IF;

  IF p_expires_days IS NOT NULL AND p_expires_days > 0 THEN
    v_expires_at := pg_catalog.clock_timestamp() + (p_expires_days * INTERVAL '1 day');
  END IF;

  v_actor := COALESCE(
    NULLIF(COALESCE(NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''), v_jwt_claims ->> 'sub'), ''),
    SESSION_USER
  );

  v_raw_token  := 'ktk_' || pg_catalog.encode(extensions.gen_random_bytes(16), 'hex');
  v_token_hash := pg_catalog.encode(extensions.digest(v_raw_token::pg_catalog.text, 'sha256'::pg_catalog.text), 'hex');

  UPDATE public.kiosk_tokens
  SET status = 'REPLACED',
      replaced_by_hash = v_token_hash,
      revoked_by = v_actor,
      revoked_at = pg_catalog.clock_timestamp(),
      revoke_reason = 'ROTATED_NEW_TOKEN'
  WHERE no_kk = v_clean_no_kk
    AND status = 'ACTIVE';

  INSERT INTO public.kiosk_tokens (
    token_hash, no_kk, status, issued_by, issued_at, expires_at
  ) VALUES (
    v_token_hash, v_clean_no_kk, 'ACTIVE', v_actor, pg_catalog.clock_timestamp(), v_expires_at
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'token', v_raw_token,
    'token_hash', v_token_hash,
    'no_kk', v_clean_no_kk,
    'expires_at', v_expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.issue_kiosk_token(TEXT, INT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.issue_kiosk_token(TEXT, INT)
  TO postgres, authenticated;


CREATE OR REPLACE FUNCTION public.revoke_kiosk_token(
  p_no_kk      TEXT,
  p_token_hash TEXT DEFAULT NULL,
  p_reason     TEXT DEFAULT 'REVOKED_BY_ADMIN'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims  pg_catalog.text;
  v_jwt_claims  pg_catalog.jsonb;
  v_jwt_role    pg_catalog.text;
  v_app_role    pg_catalog.text;
  v_actor       pg_catalog.text;
  v_clean_no_kk pg_catalog.text;
  v_revoked_cnt pg_catalog.int4 := 0;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Role "%" not permitted to revoke kiosk tokens', v_app_role USING ERRCODE = '42501';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: 16-digit p_no_kk required' USING ERRCODE = 'P0006';
  END IF;

  v_actor := COALESCE(
    NULLIF(COALESCE(NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''), v_jwt_claims ->> 'sub'), ''),
    SESSION_USER
  );

  UPDATE public.kiosk_tokens
  SET status = 'REVOKED',
      revoked_by = v_actor,
      revoked_at = pg_catalog.clock_timestamp(),
      revoke_reason = COALESCE(NULLIF(pg_catalog.btrim(p_reason), ''), 'REVOKED_BY_ADMIN')
  WHERE no_kk = v_clean_no_kk
    AND status IN ('ACTIVE', 'REPLACED')
    AND (p_token_hash IS NULL OR token_hash = pg_catalog.btrim(p_token_hash));

  GET DIAGNOSTICS v_revoked_cnt = ROW_COUNT;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'OK',
    'revoked_count', v_revoked_cnt
  );
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_kiosk_token(TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_kiosk_token(TEXT, TEXT, TEXT)
  TO postgres, authenticated;


CREATE OR REPLACE FUNCTION public.get_public_kiosk_quota(
  p_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims    pg_catalog.text;
  v_jwt_claims    pg_catalog.jsonb;
  v_jwt_role      pg_catalog.text;
  v_headers_raw   pg_catalog.text;
  v_headers       pg_catalog.jsonb := '{}'::pg_catalog.jsonb;
  v_client_ip     pg_catalog.text := 'unknown';
  v_clean_token   pg_catalog.text;
  v_token_hash    pg_catalog.text;
  v_bucket_ip     pg_catalog.text;
  v_hits_ip       pg_catalog.int4;
  v_tok           RECORD;
  v_today_wib     pg_catalog.date;
  v_window_start  pg_catalog.date;
  v_used_beras    pg_catalog.int4 := 0;
  v_used_gas      pg_catalog.int4 := 0;
  v_oldest_beras  pg_catalog.date;
  v_oldest_gas    pg_catalog.date;
  v_rem_beras     pg_catalog.int4;
  v_rem_gas       pg_catalog.int4;
  v_rec_beras     pg_catalog.date;
  v_rec_gas       pg_catalog.date;
  v_days_beras    pg_catalog.int4;
  v_days_gas      pg_catalog.int4;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'anon' THEN
    RAISE EXCEPTION 'FORBIDDEN: Public kiosk lookup permitted exclusively for anon role'
      USING ERRCODE = '42501';
  END IF;

  v_headers_raw := NULLIF(pg_catalog.current_setting('request.headers', true), '');
  IF v_headers_raw IS NOT NULL THEN
    BEGIN
      v_headers := v_headers_raw::pg_catalog.jsonb;
      v_client_ip := COALESCE(
        NULLIF(pg_catalog.btrim(pg_catalog.split_part(COALESCE(v_headers ->> 'x-forwarded-for', ''), ',', 1)), ''),
        NULLIF(pg_catalog.btrim(v_headers ->> 'cf-connecting-ip'), ''),
        'anon-client'
      );
    EXCEPTION WHEN OTHERS THEN
      v_client_ip := 'anon-client';
    END;
  END IF;

  v_clean_token := pg_catalog.btrim(COALESCE(p_token, ''));
  v_bucket_ip   := 'ip:' || pg_catalog.encode(extensions.digest(v_client_ip::pg_catalog.text, 'sha256'::pg_catalog.text), 'hex');

  INSERT INTO public.kiosk_rate_limits (bucket_key, window_started_at, hit_count)
  VALUES (v_bucket_ip, pg_catalog.clock_timestamp(), 1)
  ON CONFLICT (bucket_key) DO UPDATE
  SET hit_count = CASE
        WHEN public.kiosk_rate_limits.window_started_at < (pg_catalog.clock_timestamp() - INTERVAL '60 seconds') THEN 1
        ELSE public.kiosk_rate_limits.hit_count + 1
      END,
      window_started_at = CASE
        WHEN public.kiosk_rate_limits.window_started_at < (pg_catalog.clock_timestamp() - INTERVAL '60 seconds') THEN pg_catalog.clock_timestamp()
        ELSE public.kiosk_rate_limits.window_started_at
      END
  RETURNING hit_count INTO v_hits_ip;

  IF v_hits_ip > 50 THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'RATE_LIMITED',
      'code', '429',
      'retry_after_seconds', 60,
      'message', 'Terlalu banyak permintaan pengecekan. Silakan tunggu 1 menit sebelum mencoba kembali.'
    );
  END IF;

  IF NOT (v_clean_token ~ '^ktk_[0-9a-f]{32}$') THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'ERR_INVALID_OR_UNAVAILABLE',
      'message', 'Token kartu kuota tidak valid atau tidak tersedia.'
    );
  END IF;

  v_token_hash := pg_catalog.encode(extensions.digest(v_clean_token::pg_catalog.text, 'sha256'::pg_catalog.text), 'hex');

  SELECT kt.no_kk, kt.status, kt.expires_at
  INTO v_tok
  FROM public.kiosk_tokens kt
  WHERE kt.token_hash = v_token_hash;

  IF NOT FOUND
     OR v_tok.status NOT IN ('ACTIVE', 'REPLACED')
     OR (v_tok.expires_at IS NOT NULL AND v_tok.expires_at <= pg_catalog.clock_timestamp()) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'ERR_INVALID_OR_UNAVAILABLE',
      'message', 'Token kartu kuota tidak valid atau tidak tersedia.'
    );
  END IF;

  v_today_wib    := (pg_catalog.timezone('Asia/Jakarta', pg_catalog.clock_timestamp()))::pg_catalog.date;
  v_window_start := v_today_wib - 30;

  SELECT
    COALESCE(SUM(l.qty_beras), 0)::pg_catalog.int4,
    MIN(CASE WHEN l.qty_beras > 0 THEN l.date ELSE NULL END),
    COALESCE(SUM(l.qty_gas), 0)::pg_catalog.int4,
    MIN(CASE WHEN l.qty_gas > 0 THEN l.date ELSE NULL END)
  INTO v_used_beras, v_oldest_beras, v_used_gas, v_oldest_gas
  FROM public.logs l
  WHERE l.no_kk = v_tok.no_kk
    AND l.status = 'COMPLETED'
    AND l.date > v_window_start
    AND l.date <= v_today_wib;

  v_rem_beras := GREATEST(0, 5 - v_used_beras);
  v_rem_gas   := GREATEST(0, 5 - v_used_gas);

  IF v_used_beras > 0 AND v_oldest_beras IS NOT NULL THEN
    v_rec_beras  := v_oldest_beras + 30;
    v_days_beras := GREATEST(1, (v_rec_beras - v_today_wib)::pg_catalog.int4);
  ELSE
    v_rec_beras  := NULL;
    v_days_beras := 30;
  END IF;

  IF v_used_gas > 0 AND v_oldest_gas IS NOT NULL THEN
    v_rec_gas  := v_oldest_gas + 30;
    v_days_gas := GREATEST(1, (v_rec_gas - v_today_wib)::pg_catalog.int4);
  ELSE
    v_rec_gas  := NULL;
    v_days_gas := 30;
  END IF;

  -- Strictly Zero PII: zero no_kk, zero nama, zero member_id, zero address/phone fields
  RETURN pg_catalog.jsonb_build_object(
    'status', 'OK',
    'token_status', v_tok.status,
    'cycle_days', 30,
    'reference_date', v_today_wib,
    'beras', pg_catalog.jsonb_build_object(
      'used', v_used_beras,
      'remaining', v_rem_beras,
      'max', 5,
      'days_left', v_days_beras,
      'recovery_date', v_rec_beras
    ),
    'gas', pg_catalog.jsonb_build_object(
      'used', v_used_gas,
      'remaining', v_rem_gas,
      'max', 5,
      'days_left', v_days_gas,
      'recovery_date', v_rec_gas
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_kiosk_quota(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_kiosk_quota(TEXT)
  TO postgres, anon;


CREATE OR REPLACE FUNCTION public.report_offline_reconciliation_conflict(
  p_request_id        TEXT,
  p_no_kk             TEXT,
  p_qty_beras         INT,
  p_qty_gas           INT,
  p_conflict_code     TEXT,
  p_local_handover_at TIMESTAMPTZ,
  p_client_payload    JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_raw_claims  pg_catalog.text;
  v_jwt_claims  pg_catalog.jsonb;
  v_jwt_role    pg_catalog.text;
  v_app_role    pg_catalog.text;
  v_actor       pg_catalog.text;
  v_clean_no_kk pg_catalog.text;
  v_clean_req   pg_catalog.text;
  v_id          pg_catalog.uuid;
BEGIN
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authenticated operational session required' USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Role "%" cannot report offline reconciliation conflicts', v_app_role USING ERRCODE = '42501';
  END IF;

  v_clean_req   := pg_catalog.btrim(COALESCE(p_request_id, ''));
  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF v_clean_req = '' OR pg_catalog.length(v_clean_no_kk) <> 16 OR p_client_payload IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: valid conflict escalation parameters required' USING ERRCODE = 'P0006';
  END IF;

  v_actor := COALESCE(
    NULLIF(COALESCE(NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''), v_jwt_claims ->> 'sub'), ''),
    SESSION_USER
  );

  INSERT INTO public.offline_reconciliation_conflicts (
    request_id, operator_uid, no_kk, attempted_qty_beras, attempted_qty_gas,
    conflict_code, local_handover_at, client_payload
  ) VALUES (
    v_clean_req, v_actor, v_clean_no_kk,
    GREATEST(COALESCE(p_qty_beras, 0), 0), GREATEST(COALESCE(p_qty_gas, 0), 0),
    COALESCE(NULLIF(pg_catalog.btrim(p_conflict_code), ''), 'PHYSICAL_OVERDISPENSE_RECONCILIATION'),
    COALESCE(p_local_handover_at, pg_catalog.clock_timestamp()),
    p_client_payload
  )
  ON CONFLICT (request_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT orc.id INTO v_id
    FROM public.offline_reconciliation_conflicts orc
    WHERE orc.request_id = v_clean_req;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'RECORDED',
    'conflict_id', v_id,
    'request_id', v_clean_req
  );
END;
$$;

REVOKE ALL ON FUNCTION public.report_offline_reconciliation_conflict(
  TEXT, TEXT, INT, INT, TEXT, TIMESTAMPTZ, JSONB
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_offline_reconciliation_conflict(
  TEXT, TEXT, INT, INT, TEXT, TIMESTAMPTZ, JSONB
) TO postgres, authenticated;


-- =============================================================================
-- 7. SCHEMA RELOAD & POST-MIGRATION CATALOG ASSERTIONS
-- =============================================================================
NOTIFY pgrst, 'reload schema';

DO $$
DECLARE
  v_tbl       TEXT;
  v_priv      TEXT;
  v_bad_cfg   INT;
  v_bad_pub   INT;
  v_pol_count INT;
BEGIN
  -- Assert Category 4 kiosk tables hold 0 privileges across PUBLIC, anon, authenticated, service_role
  FOREACH v_tbl IN ARRAY ARRAY['public.kiosk_tokens', 'public.kiosk_rate_limits'] LOOP
    FOREACH v_priv IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] LOOP
      IF pg_catalog.has_table_privilege('public', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('anon', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('authenticated', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('service_role', v_tbl, v_priv) THEN
        RAISE EXCEPTION 'ASSERT_FAILED: Kiosk table % exposes % to disallowed role', v_tbl, v_priv;
      END IF;
    END LOOP;
  END LOOP;

  -- Preserve Expand SELECT policies on legacy operational tables (no 007 Contract yet)
  SELECT count(*) INTO v_pol_count
  FROM pg_catalog.pg_policies
  WHERE schemaname = 'public'
    AND policyname IN ('Staging read customers', 'Staging read logs', 'Staging read warehouse_logs');
  IF v_pol_count <> 3 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Expected 3 Staging read Expand policies to remain intact, found %', v_pol_count;
  END IF;

  -- All SECURITY DEFINER routines pinned strictly to pg_catalog and zero PUBLIC EXECUTE
  SELECT count(*) INTO v_bad_cfg
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'private_internal')
    AND p.prosecdef
    AND p.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog'];
  IF v_bad_cfg > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Found % SECURITY DEFINER function(s) without search_path=pg_catalog', v_bad_cfg;
  END IF;

  SELECT count(*) INTO v_bad_pub
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'private_internal')
    AND (p.proacl IS NULL OR pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE'));
  IF v_bad_pub > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Found % function(s) with NULL proacl or PUBLIC EXECUTE', v_bad_pub;
  END IF;

  -- Exact EXECUTE ACL parity for key new endpoints
  IF pg_catalog.has_function_privilege('authenticated', 'public.get_public_kiosk_quota(text)', 'EXECUTE') OR
     pg_catalog.has_function_privilege('service_role', 'public.get_public_kiosk_quota(text)', 'EXECUTE') OR
     NOT pg_catalog.has_function_privilege('anon', 'public.get_public_kiosk_quota(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: get_public_kiosk_quota ACL mismatch';
  END IF;

  IF pg_catalog.has_function_privilege('anon', 'public.prune_operational_change_feed_v4(interval,int4,int4)', 'EXECUTE') OR
     pg_catalog.has_function_privilege('authenticated', 'public.prune_operational_change_feed_v4(interval,int4,int4)', 'EXECUTE') OR
     NOT pg_catalog.has_function_privilege('service_role', 'public.prune_operational_change_feed_v4(interval,int4,int4)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: prune_operational_change_feed_v4 ACL mismatch';
  END IF;

  IF pg_catalog.has_function_privilege('anon', 'public.get_operational_sync_data_v4(int8,int4,int8)', 'EXECUTE') OR
     pg_catalog.has_function_privilege('service_role', 'public.get_operational_sync_data_v4(int8,int4,int8)', 'EXECUTE') OR
     NOT pg_catalog.has_function_privilege('authenticated', 'public.get_operational_sync_data_v4(int8,int4,int8)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: get_operational_sync_data_v4 ACL mismatch';
  END IF;
END
$$;
