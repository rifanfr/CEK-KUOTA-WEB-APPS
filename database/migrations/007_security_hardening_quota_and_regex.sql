-- =============================================================================
-- PHASE 4 MIGRATION 007: SECURITY HARDENING (TX DATE GUARD + ID REGEX)
-- Project: Catat Kuota KK
-- Depends on: 005_phase4_hardening_definer_and_triggers.sql,
--             006c_phase4_operator_attribution.sql
-- Purpose:
--   1. Prevent 30-day quota cycle bypass in process_quota_dispense by rejecting
--      future p_tx_date (> Asia/Jakarta today) and restricting non-admin
--      backdates to at most 7 days.
--   2. Enforce strict regex '^[A-Za-z0-9._:-]{1,64}$' on p_member_id and
--      optional p_custom_log_id across process_quota_dispense and
--      register_customer to prevent stored XSS / HTML injection payloads.
--   3. Preserve SECURITY DEFINER, SET search_path = pg_catalog, advisory locks,
--      idempotency, operator attribution, and strict EXECUTE ACLs.
-- =============================================================================

-- 1. Hardened process_quota_dispense (exact 14-arg signature preserved)
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
  v_clean_custom_log_id pg_catalog.text;
  v_today_wib           pg_catalog.date;
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

  -- Server-side WIB date guard against 30-day quota cycle bypass
  v_today_wib := (pg_catalog.now() AT TIME ZONE 'Asia/Jakarta')::pg_catalog.date;
  IF p_tx_date > v_today_wib THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal transaksi (%) tidak boleh melebihi tanggal hari ini WIB (%)',
      p_tx_date, v_today_wib
      USING ERRCODE = 'P0006';
  END IF;

  IF v_app_role <> 'admin' AND p_tx_date < (v_today_wib - INTERVAL '7 days')::pg_catalog.date THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Role "%" hanya diizinkan melakukan backdate maksimal 7 hari dari tanggal hari ini WIB (%)',
      v_app_role, v_today_wib
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
  IF NOT (v_clean_member_id ~ '^[A-Za-z0-9._:-]{1,64}$') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Format Member ID (p_member_id) tidak valid (hanya alfanumerik, titik, garis bawah, titik dua, atau strip, maks. 64 karakter)'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_custom_log_id := pg_catalog.btrim(COALESCE(p_custom_log_id, ''));
  IF v_clean_custom_log_id <> '' AND NOT (v_clean_custom_log_id ~ '^[A-Za-z0-9._:-]{1,64}$') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Format Custom Log ID (p_custom_log_id) tidak valid (hanya alfanumerik, titik, garis bawah, titik dua, atau strip, maks. 64 karakter)'
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
    NULLIF(v_clean_custom_log_id, ''),
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

  -- Step 13: Success response (exact 003/005/006c contract preserved)
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


-- 2. Hardened register_customer (exact 9-arg signature preserved + p_member_id regex)
CREATE OR REPLACE FUNCTION public.register_customer(
  p_request_id     TEXT,
  p_no_kk          TEXT,
  p_member_id      TEXT,
  p_nama           TEXT,
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
  v_v2_fingerprint      pg_catalog.text;
  v_v1_fingerprint      pg_catalog.text;
  v_existing_req        RECORD;
  v_existing_cust       RECORD;
  v_result              RECORD;
  v_actor               pg_catalog.text;
  v_raw_claims          pg_catalog.text;
  v_jwt_claims          pg_catalog.jsonb;
  v_jwt_role            pg_catalog.text;
  v_jwt_sub             pg_catalog.text;
  v_app_role            pg_catalog.text;
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
    RAISE EXCEPTION 'UNAUTHORIZED: Registrasi pelanggan mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mendaftarkan pelanggan', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Parameter validation
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id registrasi wajib disertakan dan tidak boleh kosong'
      USING ERRCODE = 'P0005';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nomor KK harus tepat 16 digit numerik (diterima: %)', p_no_kk
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_nama, '')), 'NFC');
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama pelanggan (p_nama) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_member_id, '')), 'NFC');
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;
  IF NOT (v_clean_member_id ~ '^[A-Za-z0-9._:-]{1,64}$') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Format Member ID (p_member_id) tidak valid (hanya alfanumerik, titik, garis bawah, titik dua, atau strip, maks. 64 karakter)'
      USING ERRCODE = 'P0006';
  END IF;

  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor := COALESCE(v_jwt_sub, SESSION_USER);

  -- 3. Compute canonical v2 fingerprint (+ v1 legacy compat solely for pre-005 existing ledger rows)
  v_v2_fingerprint := private_internal.calculate_canonical_fingerprint_v2(
    'REGISTER_CUSTOMER',
    pg_catalog.btrim(p_request_id),
    v_actor,
    pg_catalog.jsonb_build_object(
      'p_no_kk', v_clean_no_kk,
      'p_member_id', v_clean_member_id,
      'p_nama', v_clean_nama,
      'p_provinsi', p_provinsi,
      'p_kabupaten', p_kabupaten,
      'p_kecamatan', p_kecamatan,
      'p_desa', p_desa,
      'p_detail', p_detail
    )
  );

  v_v1_fingerprint := pg_catalog.encode(
    extensions.digest(
      (v_clean_no_kk || '|' || pg_catalog.btrim(COALESCE(p_member_id, '')) || '|' || pg_catalog.btrim(COALESCE(p_nama, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_provinsi, '')) || '|' || pg_catalog.btrim(COALESCE(p_kabupaten, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_kecamatan, '')) || '|' || pg_catalog.btrim(COALESCE(p_desa, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_detail, '')))::pg_catalog.text,
      'sha256'::pg_catalog.text
    ),
    'hex'
  );

  PERFORM pg_catalog.set_config('app.current_request_id', pg_catalog.btrim(p_request_id), true);

  -- 4. Lock Request ID
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('CUST_REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- 5. Idempotency ledger check
  SELECT request_id, no_kk, payload_fingerprint, customer_no_kk
  INTO v_existing_req
  FROM public.customer_registration_requests
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_req.payload_fingerprint IN (v_v2_fingerprint, v_v1_fingerprint) THEN
      SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
      INTO v_existing_cust
      FROM public.customers
      WHERE no_kk = v_existing_req.customer_no_kk;

      RETURN pg_catalog.jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Data pelanggan sudah tercatat sebelumnya (idempotent replay)',
        'customer', pg_catalog.to_jsonb(v_existing_cust)
      );
    ELSE
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terdaftar dengan rincian data pelanggan berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;
  END IF;

  -- 6. Lock No KK
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('KK:' || v_clean_no_kk, 0));

  SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_existing_cust
  FROM public.customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    IF pg_catalog.normalize(v_existing_cust.nama, 'NFC') <> v_clean_nama OR
       pg_catalog.normalize(v_existing_cust.member_id, 'NFC') <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Nomor KK % sudah terdaftar atas nama "%" (Member: %). Perubahan profil memerlukan RPC otorisasi khusus.',
        v_clean_no_kk, v_existing_cust.nama, v_existing_cust.member_id
        USING ERRCODE = 'P0014';
    END IF;

    INSERT INTO public.customer_registration_requests (
      request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
    ) VALUES (
      p_request_id, v_clean_no_kk, v_v2_fingerprint, v_clean_no_kk, v_actor
    ) ON CONFLICT (request_id) DO NOTHING;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Data pelanggan identik sudah terdaftar di basis data master',
      'customer', pg_catalog.to_jsonb(v_existing_cust)
    );
  END IF;

  -- 7. Register new customer (atomic audit + deferred change feed attached)
  INSERT INTO public.customers (
    no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
  ) VALUES (
    v_clean_no_kk, v_clean_member_id, v_clean_nama,
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_provinsi, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kabupaten, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kecamatan, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_desa, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_detail, '')), 'NFC')
  )
  RETURNING no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_result;

  -- 8. Write idempotency ledger
  INSERT INTO public.customer_registration_requests (
    request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
  ) VALUES (
    p_request_id, v_clean_no_kk, v_v2_fingerprint, v_clean_no_kk, v_actor
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Data Kartu Keluarga berhasil didaftarkan di master cloud',
    'customer', pg_catalog.to_jsonb(v_result)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO postgres, authenticated;
