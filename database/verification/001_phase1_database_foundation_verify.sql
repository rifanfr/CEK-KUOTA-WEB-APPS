-- =============================================================================
-- VERIFICATION SQL: PHASE 1 (DATABASE FOUNDATION)
-- Kueri assertion otomatis untuk memverifikasi keberhasilan penerapan
-- =============================================================================

-- 1. Verifikasi Kolom Baru pada logs
SELECT 
  column_name, data_type, is_nullable, column_default 
FROM information_schema.columns 
WHERE table_name = 'logs' AND column_name IN ('request_id', 'operator_id', 'status');

-- 2. Verifikasi Constraint Status
SELECT 
  conname, pg_get_constraintdef(oid) 
FROM pg_constraint 
WHERE conrelid = 'logs'::regclass AND conname = 'chk_logs_status_valid';

-- 3. Verifikasi Indeks Idempotensi logs(request_id)
SELECT 
  indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'logs' AND indexname = 'uq_logs_request_id';

-- 4. Verifikasi Indeks log_id pada warehouse_logs
SELECT 
  indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'warehouse_logs' AND indexname = 'idx_wh_log_id';

-- 5. Verifikasi Kolom Tambahan pada transaction_audit_trail
SELECT 
  column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'transaction_audit_trail' AND column_name IN ('request_id', 'operator_id');

-- 6. Verifikasi search_path Trigger Function
SELECT 
  proname, prosecdef, proconfig 
FROM pg_proc 
WHERE proname = 'capture_audit_trail_trigger';
