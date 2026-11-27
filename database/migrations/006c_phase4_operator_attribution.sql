-- =============================================================================
-- PHASE 4 MIGRATION 006c: OPERATOR ATTRIBUTION (ROLE + EMAIL + UID) ON LOGS
-- Project: Catat Kuota KK (Staging: evexaeyryfayfbffzzhh)
-- Depends on: 005_phase4_hardening_definer_and_triggers.sql,
--             006b_phase4_cashier_stock_summary_view.sql
-- Purpose: Persist server-verified operator_id, operator_email, and
--          operator_role on both public.logs and public.warehouse_logs,
--          backfill existing staging rows from transaction_audit_trail +
--          auth.users, and expose them via RPC responses & snapshot pages.
-- =============================================================================

-- 1. Idempotent column additions
ALTER TABLE public.logs
  ADD COLUMN IF NOT EXISTS operator_email TEXT,
  ADD COLUMN IF NOT EXISTS operator_role TEXT;

ALTER TABLE public.warehouse_logs
  ADD COLUMN IF NOT EXISTS operator_id TEXT,
  ADD COLUMN IF NOT EXISTS operator_email TEXT,
  ADD COLUMN IF NOT EXISTS operator_role TEXT;

-- 1b. Fix cross-table UPDATE record resolution in trg_fn_capture_change_feed_v4
--     Using v_old_json/v_new_json avoids PL/pgSQL resolving OLD.is_void on public.logs UPDATEs.
CREATE OR REPLACE FUNCTION private_internal.trg_fn_capture_change_feed_v4()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_old_pk      pg_catalog.text;
  v_new_pk      pg_catalog.text;
  v_old_json    pg_catalog.jsonb;
  v_new_json    pg_catalog.jsonb;
  v_seq         pg_catalog.int8;
  v_seq_end     pg_catalog.int8;
  v_ts          pg_catalog.timestamptz;
  v_action      pg_catalog.text;
  v_payload     pg_catalog.jsonb;
  v_rec_id      pg_catalog.text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_old_json := pg_catalog.to_jsonb(OLD);
    v_new_json := pg_catalog.to_jsonb(NEW);
    IF v_old_json IS NOT DISTINCT FROM v_new_json THEN
      RETURN NULL;
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'customers' THEN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old_pk := OLD.no_kk; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new_pk := NEW.no_kk; END IF;
  ELSE
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old_pk := OLD.id::pg_catalog.text; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new_pk := NEW.id::pg_catalog.text; END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND v_old_pk IS DISTINCT FROM v_new_pk THEN
    UPDATE public.change_feed_tracker
    SET last_committed_seq = last_committed_seq + 2,
        updated_at = pg_catalog.clock_timestamp()
    WHERE singleton_id = 1
    RETURNING last_committed_seq, updated_at INTO v_seq_end, v_ts;

    IF v_seq_end IS NULL THEN
      RAISE EXCEPTION 'CHANGE_FEED_INVARIANT: missing singleton_id = 1 in change_feed_tracker';
    END IF;

    INSERT INTO public.operational_change_feed (
      change_seq, table_name, record_id, action_type, record_data, recorded_at
    ) VALUES (
      v_seq_end - 1,
      TG_TABLE_NAME,
      v_old_pk,
      'TOMBSTONE',
      pg_catalog.jsonb_build_object(
        'table_name', TG_TABLE_NAME,
        'record_id', v_old_pk,
        'is_tombstone', true,
        'reason', 'PK_CHANGED',
        'replaced_by', v_new_pk,
        'marked_at', v_ts
      ),
      v_ts
    );

    INSERT INTO public.operational_change_feed (
      change_seq, table_name, record_id, action_type, record_data, recorded_at
    ) VALUES (
      v_seq_end,
      TG_TABLE_NAME,
      v_new_pk,
      'INSERT',
      v_new_json,
      v_ts
    );

    RETURN NULL;
  END IF;

  UPDATE public.change_feed_tracker
  SET last_committed_seq = last_committed_seq + 1,
      updated_at = pg_catalog.clock_timestamp()
  WHERE singleton_id = 1
  RETURNING last_committed_seq, updated_at INTO v_seq, v_ts;

  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'CHANGE_FEED_INVARIANT: missing singleton_id = 1 in change_feed_tracker';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_action  := 'INSERT';
    v_rec_id  := v_new_pk;
    v_payload := pg_catalog.to_jsonb(NEW);
  ELSIF TG_OP = 'DELETE' THEN
    v_action  := 'DELETE';
    v_rec_id  := v_old_pk;
    v_payload := pg_catalog.jsonb_build_object(
      'table_name', TG_TABLE_NAME,
      'record_id', v_old_pk,
      'is_deleted', true,
      'deleted_at', v_ts
    );
  ELSIF TG_OP = 'UPDATE' THEN
    v_rec_id  := v_new_pk;
    v_payload := v_new_json;
    IF TG_TABLE_NAME = 'logs' THEN
      IF (v_old_json ->> 'status') IS DISTINCT FROM (v_new_json ->> 'status')
         AND (v_new_json ->> 'status') IN ('CANCELLED', 'REFUNDED') THEN
        v_action := 'VOID';
      ELSE
        v_action := 'UPDATE';
      END IF;
    ELSIF TG_TABLE_NAME = 'warehouse_logs' THEN
      IF COALESCE((v_old_json ->> 'is_void')::pg_catalog.bool, false) = false
         AND COALESCE((v_new_json ->> 'is_void')::pg_catalog.bool, false) = true THEN
        v_action := 'VOID';
      ELSE
        v_action := 'UPDATE';
      END IF;
    ELSE
      v_action := 'UPDATE';
    END IF;
  END IF;

  INSERT INTO public.operational_change_feed (
    change_seq, table_name, record_id, action_type, record_data, recorded_at
  ) VALUES (
    v_seq, TG_TABLE_NAME, v_rec_id, v_action, v_payload, v_ts
  );

  RETURN NULL;
END;
$$;

-- 2. Idempotent backfill for existing rows on staging
WITH log_audit_actors AS (
  SELECT DISTINCT ON (t.record_id)
         t.record_id AS log_id,
         NULLIF(pg_catalog.btrim(t.changed_by), '') AS actor_uid
  FROM public.transaction_audit_trail t
  WHERE t.table_name = 'logs'
    AND t.action_type = 'INSERT'
  ORDER BY t.record_id, t.changed_at ASC
)
UPDATE public.logs l
SET operator_id = COALESCE(NULLIF(pg_catalog.btrim(l.operator_id), ''), la.actor_uid, u.id::pg_catalog.text),
    operator_email = COALESCE(NULLIF(pg_catalog.btrim(l.operator_email), ''), pg_catalog.lower(pg_catalog.btrim(u.email))),
    operator_role = COALESCE(NULLIF(pg_catalog.btrim(l.operator_role), ''), NULLIF(pg_catalog.btrim(u.raw_app_meta_data ->> 'role'), ''))
FROM log_audit_actors la
LEFT JOIN auth.users u
  ON u.id::pg_catalog.text = la.actor_uid
WHERE l.id = la.log_id
  AND (
    NULLIF(pg_catalog.btrim(l.operator_id), '') IS NULL
    OR NULLIF(pg_catalog.btrim(l.operator_email), '') IS NULL
    OR NULLIF(pg_catalog.btrim(l.operator_role), '') IS NULL
  );

-- Second targeted pass if operator_id already matched auth.users without INSERT audit record
UPDATE public.logs l
SET operator_email = COALESCE(NULLIF(pg_catalog.btrim(l.operator_email), ''), pg_catalog.lower(pg_catalog.btrim(u.email))),
    operator_role = COALESCE(NULLIF(pg_catalog.btrim(l.operator_role), ''), NULLIF(pg_catalog.btrim(u.raw_app_meta_data ->> 'role'), ''))
FROM auth.users u
WHERE NULLIF(pg_catalog.btrim(l.operator_id), '') = u.id::pg_catalog.text
  AND (
    NULLIF(pg_catalog.btrim(l.operator_email), '') IS NULL
    OR NULLIF(pg_catalog.btrim(l.operator_role), '') IS NULL
  );

WITH wh_audit_actors AS (
  SELECT DISTINCT ON (t.record_id)
         t.record_id AS wh_id,
         NULLIF(pg_catalog.btrim(t.changed_by), '') AS actor_uid
  FROM public.transaction_audit_trail t
  WHERE t.table_name = 'warehouse_logs'
    AND t.action_type = 'INSERT'
  ORDER BY t.record_id, t.changed_at ASC
)
UPDATE public.warehouse_logs w
SET operator_id = COALESCE(NULLIF(pg_catalog.btrim(w.operator_id), ''), wa.actor_uid, u.id::pg_catalog.text),
    operator_email = COALESCE(
      NULLIF(pg_catalog.btrim(w.operator_email), ''),
      pg_catalog.lower(pg_catalog.btrim(u.email))
    ),
    operator_role = COALESCE(
      NULLIF(pg_catalog.btrim(w.operator_role), ''),
      NULLIF(pg_catalog.btrim(u.raw_app_meta_data ->> 'role'), '')
    )
FROM wh_audit_actors wa
LEFT JOIN auth.users u
  ON u.id::pg_catalog.text = wa.actor_uid
WHERE w.id = wa.wh_id
  AND (
    NULLIF(pg_catalog.btrim(w.operator_id), '') IS NULL
    OR NULLIF(pg_catalog.btrim(w.operator_email), '') IS NULL
    OR NULLIF(pg_catalog.btrim(w.operator_role), '') IS NULL
  );

-- Also propagate operator metadata from linked public.logs row for auto-generated GI-WARGA rows if missing
UPDATE public.warehouse_logs w
SET operator_id = COALESCE(NULLIF(pg_catalog.btrim(w.operator_id), ''), l.operator_id),
    operator_email = COALESCE(NULLIF(pg_catalog.btrim(w.operator_email), ''), l.operator_email),
    operator_role = COALESCE(NULLIF(pg_catalog.btrim(w.operator_role), ''), l.operator_role)
FROM public.logs l
WHERE w.log_id = l.id
  AND (
    NULLIF(pg_catalog.btrim(w.operator_id), '') IS NULL
    OR NULLIF(pg_catalog.btrim(w.operator_email), '') IS NULL
    OR NULLIF(pg_catalog.btrim(w.operator_role), '') IS NULL
  );

-- 3. Update process_quota_dispense (exact 14-arg signature preserved)
CREATE OR REPLACE FUNCTION public.process_quota_dispense(
  p_request_id     TEXT,
  p_no_kk          TEXT,
  p_nama           TEXT,
  p_member_id      TEXT,
  p_qty_beras      INT,
  p_qty_gas        INT,
  p_tx_date        DATE DEFAULT CURRENT_DATE,
  p_operator_id    TEXT DEFAULT NULL,
  p_custom_log_id  TEXT DEFAULT NULL,
  p_provinsi       TEXT DEFAULT '',
  p_kabupaten      TEXT DEFAULT '',
  p_kecamatan      TEXT DEFAULT '',
  p_desa           TEXT DEFAULT '',
  p_detail         TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_no_kk         pg_catalog.text;
  v_clean_nama          pg_catalog.text;
  v_clean_member_id     pg_catalog.text;
  v_log_id              pg_catalog.text;
  v_existing_log        RECORD;
  v_cust_check          RECORD;
  v_used_beras          pg_catalog.int4 := 0;
  v_used_gas            pg_catalog.int4 := 0;
  v_stock_beras         pg_catalog.int4 := 0;
  v_stock_gas           pg_catalog.int4 := 0;
  v_actor               pg_catalog.text;
  v_op_email            pg_catalog.text;
  v_op_role             pg_catalog.text;
  v_masked_kk           pg_catalog.text;
  v_total_pcs           pg_catalog.int4;
  v_raw_claims          pg_catalog.text;
  v_jwt_claims          pg_catalog.jsonb;
  v_jwt_role            pg_catalog.text;
  v_jwt_sub             pg_catalog.text;
  v_app_role            pg_catalog.text;
BEGIN
  -- Step 1: Server-side JWT authorization without auth.role()
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Penyaluran kuota sembako mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang menyalurkan kuota', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- Step 2: Explicit validation & business constraints
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id wajib disertakan dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0005';
  END IF;

  IF p_tx_date IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal transaksi (p_tx_date) tidak boleh NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_nama, '')), 'NFC');
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama warga (p_nama) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_member_id, '')), 'NFC');
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nomor KK harus tepat 16 digit numerik (diterima: %)', p_no_kk
      USING ERRCODE = 'P0006';
  END IF;

  IF p_qty_beras IS NULL OR p_qty_gas IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Beras dan Gas tidak boleh bernilai NULL'
      USING ERRCODE = 'P0007';
  END IF;

  IF p_qty_beras < 0 OR p_qty_beras > 5 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Beras per transaksi harus antara 0 dan 5 (diterima: %)', p_qty_beras
      USING ERRCODE = 'P0007';
  END IF;

  IF p_qty_gas < 0 OR p_qty_gas > 5 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Gas per transaksi harus antara 0 dan 5 (diterima: %)', p_qty_gas
      USING ERRCODE = 'P0007';
  END IF;

  v_total_pcs := p_qty_beras + p_qty_gas;
  IF v_total_pcs <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Minimal pembelian per transaksi adalah 1 pcs'
      USING ERRCODE = 'P0008';
  END IF;

  -- Bind transaction-local request correlation for customer audit trigger
  PERFORM pg_catalog.set_config('app.current_request_id', pg_catalog.btrim(p_request_id), true);

  -- Step 3: Level 0 Lock (Request ID)
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- Step 4: Idempotency detection
  SELECT id, request_id, operator_id, operator_email, operator_role,
         date, member_id, nama, no_kk, qty_beras, qty_gas, total_pcs, status, created_at
  INTO v_existing_log
  FROM public.logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
       v_existing_log.date IS DISTINCT FROM p_tx_date OR
       pg_catalog.normalize(COALESCE(v_existing_log.member_id, ''), 'NFC') IS DISTINCT FROM v_clean_member_id OR
       v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
       v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
      'log', pg_catalog.to_jsonb(v_existing_log)
    );
  END IF;

  -- Step 5: Level 1 Lock (No KK)
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('KK:' || v_clean_no_kk, 0));

  -- Step 6: Atomic customer check / auto-registration
  SELECT no_kk, member_id, nama INTO v_cust_check
  FROM public.customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    IF pg_catalog.normalize(v_cust_check.nama, 'NFC') <> v_clean_nama OR
       pg_catalog.normalize(v_cust_check.member_id, 'NFC') <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Identitas pemohon (Nama: %, Member: %) tidak cocok dengan data master terdaftar (Nama: %, Member: %). Perubahan data master membutuhkan prosedur otorisasi khusus.',
        v_clean_nama, v_clean_member_id, v_cust_check.nama, v_cust_check.member_id
        USING ERRCODE = 'P0014';
    END IF;
  ELSE
    INSERT INTO public.customers (
      no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
    ) VALUES (
      v_clean_no_kk, v_clean_member_id, v_clean_nama,
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_provinsi, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kabupaten, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kecamatan, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_desa, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_detail, '')), 'NFC')
    );
  END IF;

  -- Step 7: Level 3 Locks (Ordered Stock: BERAS -> GAS)
  IF p_qty_beras > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:BERAS', 0));
  END IF;
  IF p_qty_gas > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:GAS', 0));
  END IF;

  -- Step 8: 30-day rolling quota check
  SELECT
    COALESCE(SUM(qty_beras), 0),
    COALESCE(SUM(qty_gas), 0)
  INTO v_used_beras, v_used_gas
  FROM public.logs
  WHERE no_kk = v_clean_no_kk
    AND status = 'COMPLETED'
    AND date > (p_tx_date - INTERVAL '30 days')
    AND date <= p_tx_date;

  IF (v_used_beras + p_qty_beras) > 5 THEN
    RAISE EXCEPTION 'QUOTA_LIMIT_EXCEEDED: Sisa kuota Beras tersisa %, permintaan % (Total akumulasi: % > 5 pcs / 30 hari)',
      (5 - v_used_beras), p_qty_beras, (v_used_beras + p_qty_beras)
      USING ERRCODE = 'P0001';
  END IF;

  IF (v_used_gas + p_qty_gas) > 5 THEN
    RAISE EXCEPTION 'QUOTA_LIMIT_EXCEEDED: Sisa kuota Gas tersisa %, permintaan % (Total akumulasi: % > 5 pcs / 30 hari)',
      (5 - v_used_gas), p_qty_gas, (v_used_gas + p_qty_gas)
      USING ERRCODE = 'P0002';
  END IF;

  -- Step 9: Warehouse balance check
  SELECT COALESCE(SUM(
    CASE
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
      ELSE 0
    END
  ), 0) INTO v_stock_beras
  FROM public.warehouse_logs WHERE item = 'beras' AND (is_void IS NOT TRUE);

  SELECT COALESCE(SUM(
    CASE
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
      ELSE 0
    END
  ), 0) INTO v_stock_gas
  FROM public.warehouse_logs WHERE item = 'gas' AND (is_void IS NOT TRUE);

  IF p_qty_beras > 0 AND v_stock_beras < p_qty_beras THEN
    RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang Beras tidak mencukupi (Tersedia: %, Dibutuhkan: %)',
      v_stock_beras, p_qty_beras
      USING ERRCODE = 'P0003';
  END IF;

  IF p_qty_gas > 0 AND v_stock_gas < p_qty_gas THEN
    RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang Gas tidak mencukupi (Tersedia: %, Dibutuhkan: %)',
      v_stock_gas, p_qty_gas
      USING ERRCODE = 'P0004';
  END IF;

  -- Step 10: ID & JWT actor attribution (server-verified sub, role, and email)
  v_log_id := COALESCE(
    NULLIF(pg_catalog.btrim(p_custom_log_id), ''),
    'LOG-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.md5(pg_catalog.random()::pg_catalog.text || pg_catalog.clock_timestamp()::pg_catalog.text), 1, 8))
  );

  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor    := COALESCE(v_jwt_sub, NULLIF(pg_catalog.btrim(p_operator_id), ''), SESSION_USER);
  v_op_role  := NULLIF(pg_catalog.btrim(v_app_role), '');
  v_op_email := NULLIF(pg_catalog.lower(pg_catalog.btrim(COALESCE(v_jwt_claims ->> 'email', ''))), '');
  IF v_op_email IS NULL AND v_jwt_sub IS NOT NULL AND v_jwt_sub ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT pg_catalog.lower(pg_catalog.btrim(u.email))
    INTO v_op_email
    FROM auth.users u
    WHERE u.id = v_jwt_sub::pg_catalog.uuid;
  END IF;

  v_masked_kk := pg_catalog.substr(v_clean_no_kk, 1, 4) || ' •••• •••• ' || pg_catalog.substr(v_clean_no_kk, 13, 4);

  -- Step 11: Atomic insert into public.logs
  BEGIN
    INSERT INTO public.logs (
      id, request_id, operator_id, operator_email, operator_role,
      date, member_id, nama, no_kk, qty_beras, qty_gas, total_pcs, status
    ) VALUES (
      v_log_id, p_request_id, v_actor, v_op_email, v_op_role,
      p_tx_date, v_clean_member_id, v_clean_nama,
      v_clean_no_kk, p_qty_beras, p_qty_gas, v_total_pcs, 'COMPLETED'
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT id, request_id, operator_id, operator_email, operator_role,
           date, member_id, nama, no_kk, qty_beras, qty_gas, total_pcs, status, created_at
    INTO v_existing_log
    FROM public.logs WHERE request_id = p_request_id;

    IF FOUND THEN
      IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
         v_existing_log.date IS DISTINCT FROM p_tx_date OR
         pg_catalog.normalize(COALESCE(v_existing_log.member_id, ''), 'NFC') IS DISTINCT FROM v_clean_member_id OR
         v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
         v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
          USING ERRCODE = 'P0009';
      END IF;

      RETURN pg_catalog.jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
        'log', pg_catalog.to_jsonb(v_existing_log)
      );
    ELSE
      RAISE;
    END IF;
  END;

  -- Step 12: Atomic insert into public.warehouse_logs
  IF p_qty_beras > 0 THEN
    INSERT INTO public.warehouse_logs (
      id, request_id, operator_id, operator_email, operator_role,
      date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-BERAS',
      'REQ-WH-BERAS-' || p_request_id,
      v_actor, v_op_email, v_op_role,
      p_tx_date, 'GI-WARGA', 'beras', p_qty_beras,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  IF p_qty_gas > 0 THEN
    INSERT INTO public.warehouse_logs (
      id, request_id, operator_id, operator_email, operator_role,
      date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-GAS',
      'REQ-WH-GAS-' || p_request_id,
      v_actor, v_op_email, v_op_role,
      p_tx_date, 'GI-WARGA', 'gas', p_qty_gas,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  -- Step 13: Success response (exact 003/005 contract preserved + operator_email/role)
  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Transaksi kuota dan mutasi stok berhasil diproses secara atomik',
    'log', pg_catalog.jsonb_build_object(
      'id', v_log_id,
      'request_id', p_request_id,
      'operator_id', v_actor,
      'operator_email', v_op_email,
      'operator_role', v_op_role,
      'date', p_tx_date,
      'member_id', v_clean_member_id,
      'nama', v_clean_nama,
      'no_kk', v_clean_no_kk,
      'qty_beras', p_qty_beras,
      'qty_gas', p_qty_gas,
      'total_pcs', v_total_pcs,
      'status', 'COMPLETED'
    ),
    'remaining_quota', pg_catalog.jsonb_build_object(
      'beras', 5 - (v_used_beras + p_qty_beras),
      'gas', 5 - (v_used_gas + p_qty_gas)
    ),
    'remaining_stock', pg_catalog.jsonb_build_object(
      'beras', v_stock_beras - p_qty_beras,
      'gas', v_stock_gas - p_qty_gas
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO postgres, authenticated;


-- 4. Update process_warehouse_mutation (exact 8-arg signature preserved)
CREATE OR REPLACE FUNCTION public.process_warehouse_mutation(
  p_request_id          TEXT,
  p_date                DATE,
  p_type                TEXT,
  p_item                TEXT,
  p_qty                 INT,
  p_ref                 TEXT DEFAULT '',
  p_operator_id         TEXT DEFAULT NULL,
  p_custom_mutation_id  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_type      pg_catalog.text;
  v_clean_item      pg_catalog.text;
  v_wh_id           pg_catalog.text;
  v_existing_wh     RECORD;
  v_stock_available pg_catalog.int4 := 0;
  v_actor           pg_catalog.text;
  v_op_email        pg_catalog.text;
  v_op_role         pg_catalog.text;
  v_raw_claims      pg_catalog.text;
  v_jwt_claims      pg_catalog.jsonb;
  v_jwt_role        pg_catalog.text;
  v_jwt_sub         pg_catalog.text;
  v_app_role        pg_catalog.text;
BEGIN
  -- 1. Server-side JWT authorization without auth.role()
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Mutasi gudang mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('supervisor', 'warehouse_admin', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mengelola mutasi gudang fisik', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Parameter validation
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id mutasi gudang wajib disertakan'
      USING ERRCODE = 'P0005';
  END IF;

  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas mutasi harus berupa bilangan bulat positif (> 0)'
      USING ERRCODE = 'P0007';
  END IF;

  IF p_date IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal mutasi tidak boleh NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_type := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_type, '')));
  IF v_clean_type NOT IN ('INITIAL-STOCK', 'GR', 'GI-MANUAL') THEN
    IF v_clean_type IN ('GR-BATAL', 'GR-REFUND') THEN
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi "%" hanya dapat diproses melalui RPC refund/batal khusus berreferensi transaksi asal', v_clean_type
        USING ERRCODE = 'P0010';
    ELSIF v_clean_type IN ('GI-WARGA', 'GI-PELANGGAN') THEN
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi "%" hanya dapat dibukukan melalui RPC penyaluran kuota warga (process_quota_dispense)', v_clean_type
        USING ERRCODE = 'P0010';
    ELSE
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi gudang "%" tidak diizinkan. Hanya INITIAL-STOCK, GR, dan GI-MANUAL yang didukung', v_clean_type
        USING ERRCODE = 'P0010';
    END IF;
  END IF;

  v_clean_item := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_item, '')));
  IF v_clean_item NOT IN ('beras', 'gas') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Komoditas "%" tidak valid (harus beras atau gas)', v_clean_item
      USING ERRCODE = 'P0006';
  END IF;

  -- 3. Lock Request ID
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('WH_REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- 4. Idempotency check
  SELECT id, request_id, operator_id, operator_email, operator_role,
         date, type, item, qty, ref, created_at
  INTO v_existing_wh
  FROM public.warehouse_logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_wh.type <> v_clean_type OR
       v_existing_wh.item <> v_clean_item OR
       v_existing_wh.qty <> p_qty OR
       v_existing_wh.date <> p_date THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terpakai dengan payload mutasi berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Mutasi gudang sudah tercatat sebelumnya (idempotent replay)',
      'warehouse_log', pg_catalog.to_jsonb(v_existing_wh)
    );
  END IF;

  -- 5. Lock warehouse commodity
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:' || pg_catalog.upper(v_clean_item), 0));

  -- 6. INITIAL-STOCK gatekeeper
  IF v_clean_type = 'INITIAL-STOCK' THEN
    IF EXISTS (
      SELECT 1 FROM public.warehouse_logs
      WHERE item = v_clean_item AND type = 'INITIAL-STOCK' AND (is_void IS NOT TRUE)
    ) THEN
      RAISE EXCEPTION 'INITIAL_STOCK_LOCKED: Saldo awal untuk komoditas % sudah pernah didaftarkan. Penambahan stok fisik wajib menggunakan GR.',
        pg_catalog.upper(v_clean_item)
        USING ERRCODE = 'P0013';
    END IF;
  END IF;

  -- 7. GI-MANUAL deficit check
  IF v_clean_type = 'GI-MANUAL' THEN
    SELECT COALESCE(SUM(
      CASE
        WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
        WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
        ELSE 0
      END
    ), 0)
    INTO v_stock_available
    FROM public.warehouse_logs
    WHERE item = v_clean_item AND (is_void IS NOT TRUE);

    IF v_stock_available < p_qty THEN
      RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang % tidak mencukupi untuk GI-MANUAL (Tersedia: %, Diminta: %)',
        pg_catalog.upper(v_clean_item), v_stock_available, p_qty
        USING ERRCODE = CASE WHEN v_clean_item = 'beras' THEN 'P0003' ELSE 'P0004' END;
    END IF;
  END IF;

  -- 8. Actor (UID, role, email) & mutation ID
  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor    := COALESCE(v_jwt_sub, NULLIF(pg_catalog.btrim(p_operator_id), ''), SESSION_USER);
  v_op_role  := NULLIF(pg_catalog.btrim(v_app_role), '');
  v_op_email := NULLIF(pg_catalog.lower(pg_catalog.btrim(COALESCE(v_jwt_claims ->> 'email', ''))), '');
  IF v_op_email IS NULL AND v_jwt_sub IS NOT NULL AND v_jwt_sub ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT pg_catalog.lower(pg_catalog.btrim(u.email))
    INTO v_op_email
    FROM auth.users u
    WHERE u.id = v_jwt_sub::pg_catalog.uuid;
  END IF;

  v_wh_id := COALESCE(
    NULLIF(pg_catalog.btrim(p_custom_mutation_id), ''),
    'WH-' || (CASE WHEN v_clean_type = 'INITIAL-STOCK' THEN 'INIT' ELSE v_clean_type END) || '-' ||
      pg_catalog.upper(pg_catalog.substr(pg_catalog.md5(pg_catalog.random()::pg_catalog.text || pg_catalog.clock_timestamp()::pg_catalog.text), 1, 8))
  );

  -- 9. Atomic insert
  INSERT INTO public.warehouse_logs (
    id, request_id, operator_id, operator_email, operator_role,
    date, type, item, qty, ref, log_id, is_void
  ) VALUES (
    v_wh_id,
    p_request_id,
    v_actor, v_op_email, v_op_role,
    p_date,
    v_clean_type,
    v_clean_item,
    p_qty,
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_ref, '')), 'NFC'),
    NULL,
    false
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Mutasi gudang berhasil dibukukan secara atomik',
    'warehouse_log', pg_catalog.jsonb_build_object(
      'id', v_wh_id,
      'request_id', p_request_id,
      'operator_id', v_actor,
      'operator_email', v_op_email,
      'operator_role', v_op_role,
      'date', p_date,
      'type', v_clean_type,
      'item', v_clean_item,
      'qty', p_qty,
      'ref', pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_ref, '')), 'NFC'),
      'created_at', pg_catalog.clock_timestamp()
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
) TO postgres, authenticated;


-- 5. Update get_operational_snapshot_page_v4 (preserving 006b Opsi A stock_summary + adding operator fields)
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
               'operator_email', l.operator_email,
               'operator_role', l.operator_role,
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
               'operator_id', w.operator_id,
               'operator_email', w.operator_email,
               'operator_role', w.operator_role,
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

NOTIFY pgrst, 'reload schema';
