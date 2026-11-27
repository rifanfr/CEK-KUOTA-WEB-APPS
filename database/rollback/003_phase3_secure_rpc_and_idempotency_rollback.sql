-- =============================================================================
-- ROLLBACK PACKAGE: PHASE 3 (SECURE RPC & SERVER-SIDE IDEMPOTENCY)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Project: Catat Kuota KK
-- Target: Non-Destructive Rollback from Phase-3 to Phase-2 State
-- Dependencies: 002_phase2_atomic_rpc_dispense.sql
-- =============================================================================
-- KEBIJAKAN NON-DESTRUKTIF (NON-DESTRUCTIVE AUDIT PRESERVATION):
-- 1. Tabel customer_registration_requests TIDAK DI-DROP agar bukti riwayat
--    idempotensi registrasi pelanggan tetap terpelihara dan dapat diaudit.
-- 2. Kolom warehouse_logs.request_id dan indeks uq_wh_request_id TIDAK DI-DROP.
-- 3. Tidak ada data transaksional atau bukti idempotensi yang dihapus/dikosongkan.
-- 4. Tabel dan kolom Fase-3 ditandai statusnya sebagai DORMANT melalui komentar skema.
-- 5. Hak eksekusi RPC Fase-3 dicabut dan fungsinya di-drop.
-- 6. RPC process_quota_dispense 9-argumen asli Fase-2 direstorasi.
-- =============================================================================

-- =============================================================================
-- 1. CABUT HAK AKSES & HAPUS RPC MUTASI GUDANG FASE-3
-- =============================================================================
REVOKE ALL ON FUNCTION public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
) FROM anon, authenticated, PUBLIC;

DROP FUNCTION IF EXISTS public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
);


-- =============================================================================
-- 2. CABUT HAK AKSES & HAPUS RPC REGISTRASI PELANGGAN FASE-3
-- =============================================================================
REVOKE ALL ON FUNCTION public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM anon, authenticated, PUBLIC;

DROP FUNCTION IF EXISTS public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);


-- =============================================================================
-- 3. CABUT HAK AKSES & HAPUS RPC PENYALURAN KUOTA FASE-3 (14 ARGUMEN)
-- =============================================================================
REVOKE ALL ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM anon, authenticated, PUBLIC;

DROP FUNCTION IF EXISTS public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);


-- =============================================================================
-- 4. RESTORASI RPC PENYALURAN KUOTA FASE-2 (9 ARGUMEN ASLI)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.process_quota_dispense(
  p_request_id TEXT,
  p_no_kk TEXT,
  p_nama TEXT,
  p_member_id TEXT,
  p_qty_beras INT,
  p_qty_gas INT,
  p_tx_date DATE DEFAULT CURRENT_DATE,
  p_operator_id TEXT DEFAULT NULL,
  p_custom_log_id TEXT DEFAULT NULL
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
  v_used_beras          INT := 0;
  v_used_gas            INT := 0;
  v_stock_beras         INT := 0;
  v_stock_gas           INT := 0;
  v_actor               TEXT;
  v_masked_kk           TEXT;
  v_total_pcs           INT;
BEGIN
  -- -------------------------------------------------------------------------
  -- STEP 1: VALIDASI INPUT EKSPLISIT & ATURAN BISNIS KUANTITAS
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
  -- STEP 2: URUTAN PENGUNCIAN DETERMINISTIK (STRICT GLOBAL LOCK HIERARCHY)
  -- -------------------------------------------------------------------------
  PERFORM pg_advisory_xact_lock(hashtextextended('REQ:' || trim(p_request_id), 0));

  -- -------------------------------------------------------------------------
  -- STEP 3: EVALUASI IDEMPOTENSI & DETEKSI KONFLIK PAYLOAD
  -- -------------------------------------------------------------------------
  SELECT 
    id, request_id, operator_id, date, member_id, nama, no_kk, 
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
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda',
        p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
      'log', to_jsonb(v_existing_log)
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('KK:' || v_clean_no_kk, 0));

  PERFORM 1 FROM customers WHERE no_kk = v_clean_no_kk FOR UPDATE;

  IF p_qty_beras > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:BERAS', 0));
  END IF;
  IF p_qty_gas > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:GAS', 0));
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 4: VALIDASI BATAS KUOTA 30 HARI
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
  -- STEP 5: VALIDASI STOK FISIK GUDANG REAL-TIME
  -- -------------------------------------------------------------------------
  SELECT 
    COALESCE(SUM(
      CASE 
        WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty 
        WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty 
        ELSE 0 
      END
    ), 0)
  INTO v_stock_beras
  FROM warehouse_logs
  WHERE item = 'beras' AND (is_void IS NOT TRUE);

  SELECT 
    COALESCE(SUM(
      CASE 
        WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty 
        WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty 
        ELSE 0 
      END
    ), 0)
  INTO v_stock_gas
  FROM warehouse_logs
  WHERE item = 'gas' AND (is_void IS NOT TRUE);

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
  -- STEP 6: PERSIAPAN IDENTITAS TRANSAKSI & OPERATOR
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
  -- STEP 7: PENYIMPANAN ATOMIK KE TABEL logs
  -- -------------------------------------------------------------------------
  BEGIN
    INSERT INTO logs (
      id, request_id, operator_id, date, member_id, nama, no_kk,
      qty_beras, qty_gas, total_pcs, status
    ) VALUES (
      v_log_id,
      p_request_id,
      v_actor,
      p_tx_date,
      v_clean_member_id,
      v_clean_nama,
      v_clean_no_kk,
      p_qty_beras,
      p_qty_gas,
      v_total_pcs,
      'COMPLETED'
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT 
      id, request_id, operator_id, date, member_id, nama, no_kk, 
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
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda',
          p_request_id
          USING ERRCODE = 'P0009';
      END IF;

      RETURN jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Transaksi sudah tercatat sebelumnya (idempotency race resolved via unique_violation)',
        'log', to_jsonb(v_existing_log)
      );
    ELSE
      RAISE;
    END IF;
  END;

  -- -------------------------------------------------------------------------
  -- STEP 8: PENYIMPANAN ATOMIK KE TABEL warehouse_logs
  -- -------------------------------------------------------------------------
  IF p_qty_beras > 0 THEN
    INSERT INTO warehouse_logs (
      id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-BERAS',
      p_tx_date,
      'GI-WARGA',
      'beras',
      p_qty_beras,
      v_clean_nama || ' (' || v_masked_kk || ')',
      v_log_id,
      false
    );
  END IF;

  IF p_qty_gas > 0 THEN
    INSERT INTO warehouse_logs (
      id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-GAS',
      p_tx_date,
      'GI-WARGA',
      'gas',
      p_qty_gas,
      v_clean_nama || ' (' || v_masked_kk || ')',
      v_log_id,
      false
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- STEP 9: KEMBALIKAN PAYLOAD SUKSES
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

-- Restorasi Hak Akses Fase-2 (Hardened: anon & PUBLIC dilarang keras mengeksekusi)
REVOKE ALL ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
) FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
) TO authenticated, service_role;


-- =============================================================================
-- 5. PRESERVASI NON-DESTRUKTIF: customer_registration_requests (DORMANT)
-- =============================================================================
-- PERINGATAN INTEGRITAS & AUDIT:
-- Tabel customer_registration_requests beserta indeksnya SENGAJA TIDAK DI-DROP.
-- Alasan: Buku besar idempotensi registrasi pelanggan berisi data historis transaksi
-- yang tidak boleh dihapus. Tabel tetap terisolasi dengan RLS aktif dan 0 tabel grants.
COMMENT ON TABLE customer_registration_requests IS 
  'DORMANT (PHASE-3 ROLLBACK): Buku besar idempotensi registrasi pelanggan dipreservasi secara non-destruktif untuk integritas bukti audit.';


-- =============================================================================
-- 6. PRESERVASI NON-DESTRUKTIF: warehouse_logs.request_id & uq_wh_request_id (DORMANT)
-- =============================================================================
-- PERINGATAN INTEGRITAS & AUDIT:
-- Kolom warehouse_logs.request_id dan indeks unik parsial uq_wh_request_id SENGAJA TIDAK DI-DROP.
-- Alasan: Menghapus kolom atau indeks ini berisiko merusak integritas referensial dan bukti
-- audit historis dari transaksi yang sempat dieksekusi selama Fase-3 aktif.
COMMENT ON COLUMN warehouse_logs.request_id IS 
  'DORMANT (PHASE-3 ROLLBACK): Kolom idempotensi mutasi gudang dipreservasi secara non-destruktif untuk audit integritas.';


-- =============================================================================
-- 7. NOTIFIKASI RELOAD SCHEMA POSTGREST
-- =============================================================================
NOTIFY pgrst, 'reload schema';


-- =============================================================================
-- 8. VERIFIKASI KEAMANAN PASCA-ROLLBACK (SECURITY POSTURE VERIFICATION)
-- Memastikan bahwa pemulihan ke Fase-2 TIDAK memberikan hak EXECUTE kepada anon/PUBLIC.
-- =============================================================================
DO $
DECLARE
  v_p2_proc_oid OID;
BEGIN
  SELECT oid INTO v_p2_proc_oid
  FROM pg_proc
  WHERE proname = 'process_quota_dispense'
    AND pronamespace = 'public'::regnamespace
    AND pronargs = 9;

  IF v_p2_proc_oid IS NULL THEN
    RAISE EXCEPTION 'ROLLBACK_VERIFY_FAILED: RPC process_quota_dispense 9-argumen tidak ditemukan';
  END IF;

  IF has_function_privilege('anon', v_p2_proc_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION_POST_ROLLBACK: anon memiliki hak EXECUTE pada RPC Fase-2 yang direstorasi';
  END IF;

  IF has_function_privilege('public', v_p2_proc_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION_POST_ROLLBACK: PUBLIC memiliki hak EXECUTE pada RPC Fase-2 yang direstorasi';
  END IF;

  IF NOT has_function_privilege('authenticated', v_p2_proc_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'CONFIG_ERROR_POST_ROLLBACK: authenticated tidak memiliki hak EXECUTE pada RPC Fase-2 yang direstorasi';
  END IF;

  RAISE NOTICE 'ROLLBACK_SECURITY_VERIFICATION_PASS: anon dan PUBLIC terbukti TIDAK memiliki EXECUTE pada process_quota_dispense (9-argumen).';
END;
$;
