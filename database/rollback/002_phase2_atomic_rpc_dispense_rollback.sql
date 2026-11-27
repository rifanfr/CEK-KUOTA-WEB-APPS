-- =============================================================================
-- ROLLBACK PACKAGE: PHASE 2 (ATOMIC RPC DISPENSE TRANSACTION)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Rollback process_quota_dispense RPC Function & Supporting Objects
-- =============================================================================

-- 1. Cabut hak akses eksekusi menggunakan signature lengkap
REVOKE EXECUTE ON FUNCTION process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
) FROM anon, authenticated, service_role;

-- 2. Hapus stored procedure RPC menggunakan signature lengkap
DROP FUNCTION IF EXISTS process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT
);

-- 3. Hapus indeks pendukung Phase-2
DROP INDEX IF EXISTS idx_wh_balance_lookup;
DROP INDEX IF EXISTS idx_logs_nokk_date;

-- 4. Hapus constraint tipe mutasi gudang yang ditambahkan di Phase-2
ALTER TABLE warehouse_logs DROP CONSTRAINT IF EXISTS chk_wh_type_valid;

-- (KOLOM is_void PADA warehouse_logs SENGAJA DIBIARKAN UTUH DEMI INTEGRITAS DATA)
