-- =============================================================================
-- VERIFICATION SQL: PHASE 2 (ATOMIC RPC DISPENSE TRANSACTION)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Assertion Keberadaan, Struktur Objek, dan Keamanan process_quota_dispense()
-- =============================================================================

-- =============================================================================
-- A. METADATA VERIFICATION
-- =============================================================================

-- A1. Verifikasi keberadaan dan konfigurasi fungsi process_quota_dispense
SELECT 
  proname, 
  prosecdef, 
  proconfig,
  pg_get_function_arguments(oid) AS arguments,
  pg_get_function_result(oid) AS return_type
FROM pg_proc 
WHERE proname = 'process_quota_dispense';

-- A2. Verifikasi hak akses (ACL) untuk role anon, authenticated, service_role
SELECT 
  routine_name, 
  grantee, 
  privilege_type 
FROM information_schema.routine_privileges 
WHERE routine_name = 'process_quota_dispense'
  AND grantee IN ('anon', 'authenticated', 'service_role');

-- A3. Verifikasi kolom is_void pada warehouse_logs
SELECT 
  column_name, 
  data_type, 
  column_default 
FROM information_schema.columns 
WHERE table_name = 'warehouse_logs' AND column_name = 'is_void';

-- A4. Verifikasi CHECK constraint chk_wh_type_valid pada warehouse_logs
SELECT 
  conname, 
  pg_get_constraintdef(oid) AS definition,
  convalidated
FROM pg_constraint 
WHERE conrelid = 'warehouse_logs'::regclass AND conname = 'chk_wh_type_valid';

-- A5. Verifikasi indeks idx_wh_balance_lookup pada warehouse_logs
SELECT 
  indexname, 
  indexdef 
FROM pg_indexes 
WHERE tablename = 'warehouse_logs' AND indexname = 'idx_wh_balance_lookup';

-- A6. Verifikasi indeks idx_logs_nokk_date pada logs
SELECT 
  indexname, 
  indexdef 
FROM pg_indexes 
WHERE tablename = 'logs' AND indexname = 'idx_logs_nokk_date';


-- =============================================================================
-- B. STATIC SQL INSPECTION
-- =============================================================================
-- Kueri ini memverifikasi bahwa kode sumber di pg_proc mematuhi aturan baku:
-- 1. Penguncian 64-bit hashtextextended berurutan
-- 2. Penolakan IDEMPOTENCY_CONFLICT
-- 3. Jendela kuota date <= p_tx_date
-- 4. Inbound stok GR-BATAL dan GR-REFUND
SELECT 
  proname,
  (prosrc LIKE '%hashtextextended%REQ:%') AS has_req_lock,
  (prosrc LIKE '%hashtextextended%KK:%') AS has_kk_lock,
  (prosrc LIKE '%hashtextextended%STOCK:BERAS%') AS has_stock_beras_lock,
  (prosrc LIKE '%hashtextextended%STOCK:GAS%') AS has_stock_gas_lock,
  (prosrc LIKE '%IDEMPOTENCY_CONFLICT%') AS has_payload_conflict_check,
  (prosrc LIKE '%date <= p_tx_date%') AS has_correct_date_window,
  (prosrc LIKE '%GR-BATAL%') AS has_gr_batal_inbound,
  (prosrc LIKE '%GR-REFUND%') AS has_gr_refund_inbound,
  (prosrc LIKE '%p_qty_beras IS NULL OR p_qty_gas IS NULL%') AS has_null_qty_rejection,
  (prosrc LIKE '%p_tx_date IS NULL%') AS has_null_date_rejection
FROM pg_proc 
WHERE proname = 'process_quota_dispense';


-- =============================================================================
-- C. BEHAVIORAL RUNTIME TESTS (PRE-FLIGHT DISCOVERY & ASSERTIONS)
-- =============================================================================

-- C1. Penemuan Tipe Mutasi Historis Non-Standar (Discovery Query)
-- Kueri ini HARUS menghasilkan 0 baris sebelum ALTER TABLE VALIDATE CONSTRAINT
SELECT 
  id, date, type, item, qty, ref 
FROM warehouse_logs 
WHERE type NOT IN (
  'INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND',
  'GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN'
);

-- C2. Uji Penolakan Parameter NULL & Kuantitas Ilegal (Dry-Run Test Block)
DO $$
DECLARE
  v_err_code TEXT;
BEGIN
  -- Uji C2.1: Tolak NULL pada kuantitas beras
  BEGIN
    PERFORM process_quota_dispense('REQ-TEST-NULL-QTY', '3201010101010001', 'UJI NULL', 'M-01', NULL, 1);
    RAISE EXCEPTION 'ASSERTION_FAILED: NULL quantity beras seharusnya ditolak!';
  EXCEPTION WHEN SQLSTATE 'P0007' THEN
    RAISE NOTICE 'ASSERTION_PASSED: NULL quantity beras berhasil ditolak (P0007).';
  END;

  -- Uji C2.2: Tolak NULL pada tanggal transaksi
  BEGIN
    PERFORM process_quota_dispense('REQ-TEST-NULL-DATE', '3201010101010001', 'UJI NULL', 'M-01', 1, 0, NULL);
    RAISE EXCEPTION 'ASSERTION_FAILED: NULL tx_date seharusnya ditolak!';
  EXCEPTION WHEN SQLSTATE 'P0006' THEN
    RAISE NOTICE 'ASSERTION_PASSED: NULL tx_date berhasil ditolak (P0006).';
  END;

  -- Uji C2.3: Tolak nama warga kosong/spasi
  BEGIN
    PERFORM process_quota_dispense('REQ-TEST-EMPTY-NAME', '3201010101010001', '   ', 'M-01', 1, 0);
    RAISE EXCEPTION 'ASSERTION_FAILED: Empty nama seharusnya ditolak!';
  EXCEPTION WHEN SQLSTATE 'P0006' THEN
    RAISE NOTICE 'ASSERTION_PASSED: Empty nama warga berhasil ditolak (P0006).';
  END;
END $$;


-- =============================================================================
-- D. TWO-SESSION CONCURRENCY & EXPOSURE TESTS
-- =============================================================================

-- D1. Verifikasi Paparan Hak Akses Role anon (RPC Callable, Direct Table Restricted)
SELECT 
  table_name, 
  privilege_type 
FROM information_schema.role_table_grants 
WHERE grantee = 'anon' 
  AND table_name IN ('logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY table_name, privilege_type;

-- D2. Verifikasi Isolasi Advisory Lock 64-bit pada pg_locks
SELECT 
  locktype, 
  classid, 
  objid, 
  mode, 
  granted 
FROM pg_locks 
WHERE locktype = 'advisory';
