-- =============================================================================
-- PHASE 4 MIGRATION 006b: CASHIER VIEW-ONLY STOCK_SUMMARY (OPSI A)
-- Project: Catat Kuota KK (Staging: evexaeyryfayfbffzzhh)
-- Depends on: 006_phase4_expand_sync_and_kiosk_rpcs.sql
-- Purpose: Allow role 'cashier' to read aggregate stock_summary (beras & gas)
--          via snapshot & delta sync RPCs, while keeping raw warehouse_logs
--          and all warehouse write RPCs (process_warehouse_mutation) forbidden.
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
    -- Opsi A: cashier reads customers, logs, and aggregate stock_summary (raw warehouse_logs stays FORBIDDEN)
    IF v_clean_section NOT IN ('customers', 'logs', 'stock_summary') THEN
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
    WHERE v_app_role IN ('cashier', 'warehouse_admin', 'supervisor', 'admin')
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
    CASE WHEN v_app_role IN ('cashier', 'warehouse_admin', 'supervisor', 'admin') THEN
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
