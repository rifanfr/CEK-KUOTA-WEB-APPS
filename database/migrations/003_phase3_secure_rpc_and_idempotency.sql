-- =============================================================================
-- MIGRATION: 003_phase3_secure_rpc_and_idempotency.sql
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Project: Catat Kuota KK
-- Target: Staging & Production Unified Secure RPC Package
-- Dependencies: 001_phase1_database_foundation.sql, 002_phase2_atomic_rpc_dispense.sql
-- =============================================================================

-- Pastikan ekstensi kriptografi aktif
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- =============================================================================
-- 1. BUKU BESAR IDEMPOTENSI REGISTRASI PELANGGAN (CUSTOMER REGISTRATION REQUESTS)
-- =============================================================================
CREATE TABLE IF NOT EXISTS customer_registration_requests (
  request_id          TEXT PRIMARY KEY,
  no_kk               TEXT NOT NULL,
  payload_fingerprint TEXT NOT NULL,
  customer_no_kk      TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by          TEXT DEFAULT current_user
);

-- Indeks lookup riwayat registrasi per Nomor KK
CREATE INDEX IF NOT EXISTS idx_cust_reg_req_nokk 
ON customer_registration_requests (no_kk, created_at DESC);

-- Kunci tabel secara total: Row Level Security aktif, cabut seluruh akses tabel
ALTER TABLE customer_registration_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE customer_registration_requests FROM anon, authenticated, PUBLIC;

COMMENT ON TABLE customer_registration_requests IS 'Buku besar idempotensi server-side untuk registrasi pelanggan. Hanya diakses oleh fungsi SECURITY DEFINER.';
COMMENT ON COLUMN customer_registration_requests.request_id IS 'UUID unik transaksi registrasi dari peramban kasir (Primary Key)';
COMMENT ON COLUMN customer_registration_requests.payload_fingerprint IS 'Hash SHA-256 dari seluruh payload data identitas pelanggan';
COMMENT ON COLUMN customer_registration_requests.customer_no_kk IS 'Nomor KK yang berhasil didaftarkan';


-- =============================================================================
-- 2. EKSTENSI IDEMPOTENSI PADA TABEL WAREHOUSE_LOGS
-- =============================================================================
ALTER TABLE warehouse_logs
  ADD COLUMN IF NOT EXISTS request_id TEXT;

-- Indeks unik parsial: menjamin 1 request_id hanya menghasilkan 1 mutasi gudang
CREATE UNIQUE INDEX IF NOT EXISTS uq_wh_request_id 
ON warehouse_logs (request_id) 
WHERE request_id IS NOT NULL;

COMMENT ON COLUMN warehouse_logs.request_id IS 'ID Transaksi unik untuk proteksi idempotensi mutasi gudang fisik';


-- =============================================================================
-- 3. MIGRASI & DISAMBIGUASI SIGNATURE process_quota_dispense (14 ARGUMENTS)
-- =============================================================================
-- Langkah 3.1: Cabut hak eksekusi dan drop signature lama 9-argumen untuk cegah ambigu PostgREST
REVOKE EXECUTE ON FUNCTION public.process_quota_dispense(TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT) FROM anon, authenticated, PUBLIC;
DROP FUNCTION IF EXISTS public.process_quota_dispense(TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT);

-- Langkah 3.2: Buat signature definitif 14-argumen
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
SET search_path = public
AS $$
DECLARE
  v_clean_no_kk         TEXT;
  v_clean_nama          TEXT;
  v_clean_member_id     TEXT;
  v_log_id              TEXT;
  v_existing_log        RECORD;
  v_cust_check          RECORD;
  v_used_beras          INT := 0;
  v_used_gas            INT := 0;
  v_stock_beras         INT := 0;
  v_stock_gas           INT := 0;
  v_actor               TEXT;
  v_masked_kk           TEXT;
  v_total_pcs           INT;
  v_jwt_claims          JSONB;
  v_app_role            TEXT;
BEGIN
  -- -------------------------------------------------------------------------
  -- STEP 1: OTORISASI SERVER-SIDE BERBASIS SUPABASE AUTH JWT
  -- -------------------------------------------------------------------------
  IF auth.role() IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Penyaluran kuota sembako mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_jwt_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_app_role   := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang menyalurkan kuota', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 2: VALIDASI INPUT EKSPLISIT & ATURAN BISNIS KUANTITAS
  -- -------------------------------------------------------------------------
  IF p_request_id IS NULL OR trim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id wajib disertakan dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0005';
  END IF;

  IF p_tx_date IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal transaksi (p_tx_date) tidak boleh NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := trim(COALESCE(p_nama, ''));
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama warga (p_nama) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := trim(COALESCE(p_member_id, ''));
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_no_kk := regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF length(v_clean_no_kk) <> 16 THEN
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

  -- -------------------------------------------------------------------------
  -- STEP 3: URUTAN PENGUNCIAN DETERMINISTIK: LOCK A (REQUEST ID)
  -- -------------------------------------------------------------------------
  PERFORM pg_advisory_xact_lock(hashtextextended('REQ:' || trim(p_request_id), 0));

  -- -------------------------------------------------------------------------
  -- STEP 4: DETEKSI IDEMPOTENSI & KONFLIK PAYLOAD
  -- -------------------------------------------------------------------------
  SELECT id, request_id, operator_id, date, member_id, nama, no_kk,
         qty_beras, qty_gas, total_pcs, status, created_at
  INTO v_existing_log
  FROM logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
       v_existing_log.date IS DISTINCT FROM p_tx_date OR
       v_existing_log.member_id IS DISTINCT FROM v_clean_member_id OR
       v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
       v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
      'log', to_jsonb(v_existing_log)
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 5: URUTAN PENGUNCIAN DETERMINISTIK: LOCK B (NO KK)
  -- -------------------------------------------------------------------------
  PERFORM pg_advisory_xact_lock(hashtextextended('KK:' || v_clean_no_kk, 0));

  -- -------------------------------------------------------------------------
  -- STEP 6: VALIDASI & REGISTRASI ATOMIK PELANGGAN (ANTI-SILENT OVERWRITE)
  -- -------------------------------------------------------------------------
  SELECT no_kk, member_id, nama INTO v_cust_check
  FROM customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    -- Pelanggan sudah ada di master: DILARANG overwrite! Verifikasi kecocokan identitas
    IF v_cust_check.nama <> v_clean_nama OR v_cust_check.member_id <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Identitas pemohon (Nama: %, Member: %) tidak cocok dengan data master terdaftar (Nama: %, Member: %). Perubahan data master membutuhkan prosedur otorisasi khusus.',
        v_clean_nama, v_clean_member_id, v_cust_check.nama, v_cust_check.member_id
        USING ERRCODE = 'P0014';
    END IF;
  ELSE
    -- Pelanggan belum ada: Daftarkan secara atomik di dalam transaksi ini
    INSERT INTO customers (
      no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
    ) VALUES (
      v_clean_no_kk, v_clean_member_id, v_clean_nama,
      trim(COALESCE(p_provinsi, '')), trim(COALESCE(p_kabupaten, '')),
      trim(COALESCE(p_kecamatan, '')), trim(COALESCE(p_desa, '')),
      trim(COALESCE(p_detail, ''))
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 7: URUTAN PENGUNCIAN DETERMINISTIK: LOCK C & D (STOCK GUDANG)
  -- -------------------------------------------------------------------------
  IF p_qty_beras > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:BERAS', 0));
  END IF;
  IF p_qty_gas > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:GAS', 0));
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 8: EVALUASI KUOTA 30 HARI
  -- -------------------------------------------------------------------------
  SELECT 
    COALESCE(SUM(qty_beras), 0),
    COALESCE(SUM(qty_gas), 0)
  INTO v_used_beras, v_used_gas
  FROM logs
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

  -- -------------------------------------------------------------------------
  -- STEP 9: VALIDASI SALDO FISIK STOK GUDANG
  -- -------------------------------------------------------------------------
  SELECT COALESCE(SUM(
    CASE 
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty 
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty 
      ELSE 0 
    END
  ), 0) INTO v_stock_beras
  FROM warehouse_logs WHERE item = 'beras' AND (is_void IS NOT TRUE);

  SELECT COALESCE(SUM(
    CASE 
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty 
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty 
      ELSE 0 
    END
  ), 0) INTO v_stock_gas
  FROM warehouse_logs WHERE item = 'gas' AND (is_void IS NOT TRUE);

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

  -- -------------------------------------------------------------------------
  -- STEP 10: PERSIAPAN IDENTITAS TRANSAKSI & AUDIT ACTOR
  -- -------------------------------------------------------------------------
  v_log_id := COALESCE(
    NULLIF(trim(p_custom_log_id), ''),
    'LOG-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8))
  );

  v_actor := COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    NULLIF(trim(p_operator_id), ''),
    current_user
  );

  v_masked_kk := substr(v_clean_no_kk, 1, 4) || ' •••• •••• ' || substr(v_clean_no_kk, 13, 4);

  -- -------------------------------------------------------------------------
  -- STEP 11: PENYIMPANAN ATOMIK KE TABEL logs
  -- -------------------------------------------------------------------------
  BEGIN
    INSERT INTO logs (
      id, request_id, operator_id, date, member_id, nama, no_kk,
      qty_beras, qty_gas, total_pcs, status
    ) VALUES (
      v_log_id, p_request_id, v_actor, p_tx_date, v_clean_member_id, v_clean_nama,
      v_clean_no_kk, p_qty_beras, p_qty_gas, v_total_pcs, 'COMPLETED'
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT id, request_id, operator_id, date, member_id, nama, no_kk,
           qty_beras, qty_gas, total_pcs, status, created_at
    INTO v_existing_log
    FROM logs WHERE request_id = p_request_id;

    IF FOUND THEN
      IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
         v_existing_log.date IS DISTINCT FROM p_tx_date OR
         v_existing_log.member_id IS DISTINCT FROM v_clean_member_id OR
         v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
         v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
          USING ERRCODE = 'P0009';
      END IF;

      RETURN jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay race)',
        'log', to_jsonb(v_existing_log)
      );
    ELSE
      RAISE;
    END IF;
  END;

  -- -------------------------------------------------------------------------
  -- STEP 12: PENYIMPANAN ATOMIK KE TABEL warehouse_logs
  -- -------------------------------------------------------------------------
  IF p_qty_beras > 0 THEN
    INSERT INTO warehouse_logs (
      id, request_id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-BERAS',
      'REQ-WH-BERAS-' || p_request_id,
      p_tx_date, 'GI-WARGA', 'beras', p_qty_beras,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  IF p_qty_gas > 0 THEN
    INSERT INTO warehouse_logs (
      id, request_id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-GAS',
      'REQ-WH-GAS-' || p_request_id,
      p_tx_date, 'GI-WARGA', 'gas', p_qty_gas,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 13: PAYLOAD RESPON SUKSES
  -- -------------------------------------------------------------------------
  RETURN jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Transaksi kuota dan mutasi stok berhasil diproses secara atomik',
    'log', jsonb_build_object(
      'id', v_log_id,
      'request_id', p_request_id,
      'operator_id', v_actor,
      'date', p_tx_date,
      'member_id', v_clean_member_id,
      'nama', v_clean_nama,
      'no_kk', v_clean_no_kk,
      'qty_beras', p_qty_beras,
      'qty_gas', p_qty_gas,
      'total_pcs', v_total_pcs,
      'status', 'COMPLETED'
    ),
    'remaining_quota', jsonb_build_object(
      'beras', 5 - (v_used_beras + p_qty_beras),
      'gas', 5 - (v_used_gas + p_qty_gas)
    ),
    'remaining_stock', jsonb_build_object(
      'beras', v_stock_beras - p_qty_beras,
      'gas', v_stock_gas - p_qty_gas
    )
  );
END;
$$;

-- Hak Akses: Cabut dari anon & PUBLIC, berikan hanya kepada authenticated
REVOKE ALL ON FUNCTION public.process_quota_dispense(TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_quota_dispense(TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;


-- =============================================================================
-- 4. RPC BARU: public.register_customer (9 ARGUMENTS)
-- =============================================================================
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
SET search_path = public, extensions
AS $$
DECLARE
  v_clean_no_kk         TEXT;
  v_clean_nama          TEXT;
  v_clean_member_id     TEXT;
  v_payload_fingerprint TEXT;
  v_existing_req        RECORD;
  v_existing_cust       RECORD;
  v_result              RECORD;
  v_actor               TEXT;
  v_jwt_claims          JSONB;
  v_app_role            TEXT;
BEGIN
  -- 1. Evaluasi Otorisasi Server-Side
  IF auth.role() IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Registrasi pelanggan mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_jwt_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_app_role   := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mendaftarkan pelanggan', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Validasi Parameter Wajib
  IF p_request_id IS NULL OR trim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id registrasi wajib disertakan dan tidak boleh kosong'
      USING ERRCODE = 'P0005';
  END IF;

  v_clean_no_kk := regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nomor KK harus tepat 16 digit numerik (diterima: %)', p_no_kk
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := trim(COALESCE(p_nama, ''));
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama pelanggan (p_nama) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := trim(COALESCE(p_member_id, ''));
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;

  -- 3. Hitung Payload Fingerprint SHA-256
  -- Menggunakan extensions.digest dengan parameter bertipe text eksplisit
  v_payload_fingerprint := encode(
    extensions.digest(
      (v_clean_no_kk || '|' || v_clean_member_id || '|' || v_clean_nama || '|' ||
       trim(COALESCE(p_provinsi, '')) || '|' || trim(COALESCE(p_kabupaten, '')) || '|' ||
       trim(COALESCE(p_kecamatan, '')) || '|' || trim(COALESCE(p_desa, '')) || '|' ||
       trim(COALESCE(p_detail, '')))::text,
      'sha256'::text
    ),
    'hex'
  );

  -- 4. Kunci Request ID (Serialisasi Idempotensi)
  PERFORM pg_advisory_xact_lock(hashtextextended('CUST_REQ:' || trim(p_request_id), 0));

  -- 5. Cek Buku Besar Idempotensi customer_registration_requests
  SELECT request_id, no_kk, payload_fingerprint, customer_no_kk
  INTO v_existing_req
  FROM customer_registration_requests
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_req.payload_fingerprint = v_payload_fingerprint THEN
      SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
      INTO v_existing_cust
      FROM customers
      WHERE no_kk = v_existing_req.customer_no_kk;

      RETURN jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Data pelanggan sudah tercatat sebelumnya (idempotent replay)',
        'customer', to_jsonb(v_existing_cust)
      );
    ELSE
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terdaftar dengan rincian data pelanggan berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;
  END IF;

  -- 6. Kunci Nomor KK untuk Evaluasi Master Customer
  PERFORM pg_advisory_xact_lock(hashtextextended('KK:' || v_clean_no_kk, 0));

  SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_existing_cust
  FROM customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    -- Verifikasi keselarasan identitas
    IF v_existing_cust.nama <> v_clean_nama OR v_existing_cust.member_id <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Nomor KK % sudah terdaftar atas nama "%" (Member: %). Perubahan profil memerlukan RPC otorisasi khusus.',
        v_clean_no_kk, v_existing_cust.nama, v_existing_cust.member_id
        USING ERRCODE = 'P0014';
    END IF;

    -- Catat ke buku besar idempotensi jika belum ada
    v_actor := COALESCE(
      NULLIF(current_setting('request.jwt.claim.sub', true), ''),
      current_user
    );

    INSERT INTO customer_registration_requests (
      request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
    ) VALUES (
      p_request_id, v_clean_no_kk, v_payload_fingerprint, v_clean_no_kk, v_actor
    ) ON CONFLICT (request_id) DO NOTHING;

    RETURN jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Data pelanggan identik sudah terdaftar di basis data master',
      'customer', to_jsonb(v_existing_cust)
    );
  END IF;

  -- 7. Daftarkan Customer Baru Secara Bersih
  INSERT INTO customers (
    no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
  ) VALUES (
    v_clean_no_kk, v_clean_member_id, v_clean_nama,
    trim(COALESCE(p_provinsi, '')), trim(COALESCE(p_kabupaten, '')),
    trim(COALESCE(p_kecamatan, '')), trim(COALESCE(p_desa, '')),
    trim(COALESCE(p_detail, ''))
  )
  RETURNING no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_result;

  -- 8. Tulis Buku Besar Idempotensi Secara Atomik
  v_actor := COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    current_user
  );

  INSERT INTO customer_registration_requests (
    request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
  ) VALUES (
    p_request_id, v_clean_no_kk, v_payload_fingerprint, v_clean_no_kk, v_actor
  );

  RETURN jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Data Kartu Keluarga berhasil didaftarkan di master cloud',
    'customer', to_jsonb(v_result)
  );
END;
$$;

-- Hak Akses: Cabut dari anon & PUBLIC, berikan hanya kepada authenticated
REVOKE ALL ON FUNCTION public.register_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;


-- =============================================================================
-- 5. RPC BARU: public.process_warehouse_mutation (8 ARGUMENTS)
-- =============================================================================
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
SET search_path = public
AS $$
DECLARE
  v_clean_type      TEXT;
  v_clean_item      TEXT;
  v_wh_id           TEXT;
  v_existing_wh     RECORD;
  v_stock_available INT := 0;
  v_actor           TEXT;
  v_jwt_claims      JSONB;
  v_app_role        TEXT;
BEGIN
  -- 1. Evaluasi Otorisasi Server-Side Supervisor / Admin
  IF auth.role() IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Mutasi gudang mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_jwt_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_app_role   := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('supervisor', 'warehouse_admin', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mengelola mutasi gudang fisik', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Validasi Parameter Wajib
  IF p_request_id IS NULL OR trim(p_request_id) = '' THEN
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

  v_clean_type := upper(trim(COALESCE(p_type, '')));
  -- Batasan Fase-3: Hanya INITIAL-STOCK, GR, dan GI-MANUAL yang diizinkan
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

  v_clean_item := lower(trim(COALESCE(p_item, '')));
  IF v_clean_item NOT IN ('beras', 'gas') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Komoditas "%" tidak valid (harus beras atau gas)', v_clean_item
      USING ERRCODE = 'P0006';
  END IF;

  -- 3. Kunci Request ID Mutasi Gudang
  PERFORM pg_advisory_xact_lock(hashtextextended('WH_REQ:' || trim(p_request_id), 0));

  -- 4. Deteksi Idempotensi Mutasi Gudang
  SELECT id, request_id, date, type, item, qty, ref, created_at
  INTO v_existing_wh
  FROM warehouse_logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_wh.type <> v_clean_type OR
       v_existing_wh.item <> v_clean_item OR
       v_existing_wh.qty <> p_qty OR
       v_existing_wh.date <> p_date THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terpakai dengan payload mutasi berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Mutasi gudang sudah tercatat sebelumnya (idempotent replay)',
      'warehouse_log', to_jsonb(v_existing_wh)
    );
  END IF;

  -- 5. Kunci Stok Komoditas Gudang
  PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:' || upper(v_clean_item), 0));

  -- 6. Gatekeeper Pembatasan INITIAL-STOCK (Hanya 1 kali per komoditas)
  IF v_clean_type = 'INITIAL-STOCK' THEN
    IF EXISTS (
      SELECT 1 FROM warehouse_logs 
      WHERE item = v_clean_item AND type = 'INITIAL-STOCK' AND (is_void IS NOT TRUE)
    ) THEN
      RAISE EXCEPTION 'INITIAL_STOCK_LOCKED: Saldo awal untuk komoditas % sudah pernah didaftarkan. Penambahan stok fisik wajib menggunakan GR.',
        upper(v_clean_item)
        USING ERRCODE = 'P0013';
    END IF;
  END IF;

  -- 7. Pengecekan Defisit Stok khusus Pengeluaran Manual (GI-MANUAL)
  IF v_clean_type = 'GI-MANUAL' THEN
    SELECT COALESCE(SUM(
      CASE 
        WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty 
        WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty 
        ELSE 0 
      END
    ), 0)
    INTO v_stock_available
    FROM warehouse_logs
    WHERE item = v_clean_item AND (is_void IS NOT TRUE);

    IF v_stock_available < p_qty THEN
      RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang % tidak mencukupi untuk GI-MANUAL (Tersedia: %, Diminta: %)',
        upper(v_clean_item), v_stock_available, p_qty
        USING ERRCODE = CASE WHEN v_clean_item = 'beras' THEN 'P0003' ELSE 'P0004' END;
    END IF;
  END IF;

  -- 8. Identitas Pelaksana & ID Mutasi
  v_actor := COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    NULLIF(trim(p_operator_id), ''),
    current_user
  );

  v_wh_id := COALESCE(
    NULLIF(trim(p_custom_mutation_id), ''),
    'WH-' || (CASE WHEN v_clean_type = 'INITIAL-STOCK' THEN 'INIT' ELSE v_clean_type END) || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8))
  );

  -- 9. Penyimpanan Atomik ke warehouse_logs
  INSERT INTO warehouse_logs (
    id, request_id, date, type, item, qty, ref, log_id, is_void
  ) VALUES (
    v_wh_id,
    p_request_id,
    p_date,
    v_clean_type,
    v_clean_item,
    p_qty,
    trim(COALESCE(p_ref, '')),
    NULL,
    false
  );

  RETURN jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Mutasi gudang berhasil dibukukan secara atomik',
    'warehouse_log', jsonb_build_object(
      'id', v_wh_id,
      'request_id', p_request_id,
      'date', p_date,
      'type', v_clean_type,
      'item', v_clean_item,
      'qty', p_qty,
      'ref', trim(COALESCE(p_ref, '')),
      'operator_id', v_actor
    )
  );
END;
$$;

-- Hak Akses: Cabut dari anon & PUBLIC, berikan hanya kepada authenticated
REVOKE ALL ON FUNCTION public.process_warehouse_mutation(TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_warehouse_mutation(TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT) TO authenticated;


-- =============================================================================
-- 6. NOTIFIKASI RELOAD SCHEMA KE POSTGREST GATEWAY
-- =============================================================================
NOTIFY pgrst, 'reload schema';
