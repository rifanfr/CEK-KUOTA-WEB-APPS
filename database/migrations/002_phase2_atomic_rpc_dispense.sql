-- =============================================================================
-- RELEASE CANDIDATE MIGRATION PACKAGE: PHASE 2 (ATOMIC RPC DISPENSE)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Atomic Quota & Stock Dispense, Strict Hierarchical Locks, & Payload Idempotency
-- =============================================================================

-- 1. PERSIAPAN STRUKTUR, INDEX, & CONSTRAINT WAREHOUSE
ALTER TABLE warehouse_logs 
  ADD COLUMN IF NOT EXISTS is_void BOOLEAN DEFAULT false;

-- Constraint tipe mutasi gudang yang diizinkan (ditambahkan sebagai NOT VALID terlebih dahulu
-- agar aman terhadap data historis yang belum diaudit)
ALTER TABLE warehouse_logs
  DROP CONSTRAINT IF EXISTS chk_wh_type_valid;

ALTER TABLE warehouse_logs
  ADD CONSTRAINT chk_wh_type_valid
  CHECK (type IN (
    'INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND',
    'GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN'
  )) NOT VALID;

-- Indeks komposit lookup saldo stok fisik gudang
CREATE INDEX IF NOT EXISTS idx_wh_balance_lookup 
ON warehouse_logs(item, type, is_void);

-- Indeks komposit pencarian riwayat kuota per KK 30 hari
CREATE INDEX IF NOT EXISTS idx_logs_nokk_date 
ON logs(no_kk, date DESC);


-- 2. ATOMIC RPC STORED PROCEDURE: process_quota_dispense
CREATE OR REPLACE FUNCTION process_quota_dispense(
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
  -- Tolak nilai NULL secara eksplisit pada seluruh parameter wajib
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

  -- Tolak NULL pada kuantitas secara eksplisit
  IF p_qty_beras IS NULL OR p_qty_gas IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Beras dan Gas tidak boleh bernilai NULL'
      USING ERRCODE = 'P0007';
  END IF;

  -- Aturan kuantitas per transaksi: batas mandiri 0 - 5 per komoditas
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
  -- Hirarki total pencegah deadlock (Dijkstra Linear Ordering):
  --   A. Lock REQ:   hashtextextended('REQ:' || trim(p_request_id), 0)
  --   B. Lock KK:    hashtextextended('KK:' || v_clean_no_kk, 0)
  --   C. Lock BERAS: hashtextextended('STOCK:BERAS', 0) (jika p_qty_beras > 0)
  --   D. Lock GAS:   hashtextextended('STOCK:GAS', 0)   (jika p_qty_gas > 0)

  -- A. Serialisasi transaksi pada level request_id
  PERFORM pg_advisory_xact_lock(hashtextextended('REQ:' || trim(p_request_id), 0));


  -- -------------------------------------------------------------------------
  -- STEP 3: EVALUASI IDEMPOTENSI & DETEKSI KONFLIK PAYLOAD (PRE-EXECUTION)
  -- -------------------------------------------------------------------------
  SELECT 
    id, request_id, operator_id, date, member_id, nama, no_kk, 
    qty_beras, qty_gas, total_pcs, status, created_at
  INTO v_existing_log
  FROM logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    -- Validasi keselarasan payload bisnis (Payload Matching)
    IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
       v_existing_log.date IS DISTINCT FROM p_tx_date OR
       v_existing_log.member_id IS DISTINCT FROM v_clean_member_id OR
       v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
       v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda',
        p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    -- Payload identik: kembalikan sukses idempoten tanpa mutasi ulang
    RETURN jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
      'log', to_jsonb(v_existing_log)
    );
  END IF;

  -- B. Serialisasi transaksi pada level No KK
  PERFORM pg_advisory_xact_lock(hashtextextended('KK:' || v_clean_no_kk, 0));

  -- Kunci baris customers jika sudah terdaftar
  PERFORM 1 FROM customers WHERE no_kk = v_clean_no_kk FOR UPDATE;

  -- C & D. Serialisasi stok fisik gudang per komoditas
  IF p_qty_beras > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:BERAS', 0));
  END IF;
  IF p_qty_gas > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('STOCK:GAS', 0));
  END IF;


  -- -------------------------------------------------------------------------
  -- STEP 4: VALIDASI BATAS KUOTA 30 HARI DENGAN JENDELA TANGGAL KOREK
  -- -------------------------------------------------------------------------
  -- Batas mandiri: Maks. 5 Beras & Maks. 5 Gas per 30 hari.
  -- Jendela waktu: date > (p_tx_date - INTERVAL '30 days') AND date <= p_tx_date
  -- Transaksi berstatus COMPLETED di masa depan (jika ada backdating) tidak bocor ke perhitungan.
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
  -- STEP 5: VALIDASI STOK FISIK GUDANG REAL-TIME (STRICT DIRECTION HANDLING)
  -- -------------------------------------------------------------------------
  -- Inbound (+): INITIAL-STOCK, GR, GR-BATAL, GR-REFUND
  -- Outbound (-): GI, GI-WARGA, GI-MANUAL, GI-PELANGGAN
  -- Unknown: bernilai 0 (tidak diasumsikan sebagai outbound)
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

  -- CATATAN KEAMANAN OPERATOR:
  -- Nilai p_operator_id dilaporkan oleh klien (client-reported) dan bersifat UNTRUSTED.
  -- Penegakan otorisasi produksi sesungguhnya tetap membutuhkan Supabase Auth (JWT sub),
  -- verified Edge Function, atau mekanisme identitas server-side lainnya.
  v_actor := COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    NULLIF(trim(p_operator_id), ''),
    current_user
  );

  v_masked_kk := substr(v_clean_no_kk, 1, 4) || ' •••• •••• ' || substr(v_clean_no_kk, 13, 4);


  -- -------------------------------------------------------------------------
  -- STEP 7: PENYIMPANAN ATOMIK KE TABEL logs (DEFENSE-IN-DEPTH UNIQUE VIOLATION)
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
    -- Pertahanan lapis ganda jika terjadi kondisi benturan unik ekstrem
    SELECT 
      id, request_id, operator_id, date, member_id, nama, no_kk, 
      qty_beras, qty_gas, total_pcs, status, created_at
    INTO v_existing_log
    FROM logs
    WHERE request_id = p_request_id;

    IF FOUND THEN
      -- Validasi payload pada lapis pertahanan exception
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


-- 3. HAK AKSES EKSEKUSI RPC UNTUK KLIEN WEB (LENGKAP DENGAN SIGNATURE)
REVOKE ALL ON FUNCTION process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
) TO anon, authenticated, service_role;
