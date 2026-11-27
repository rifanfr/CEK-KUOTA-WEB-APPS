-- =============================================================================
-- STAGING BASELINE ROLLBACK
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Membersihkan seluruh objek baseline skema pada proyek Staging disposable
-- =============================================================================

-- 1. Cabut Policy RLS
DROP POLICY IF EXISTS "Staging allow all customers" ON customers;
DROP POLICY IF EXISTS "Staging read customers" ON customers;
DROP POLICY IF EXISTS "Staging allow all logs" ON logs;
DROP POLICY IF EXISTS "Staging read logs" ON logs;
DROP POLICY IF EXISTS "Staging allow all warehouse_logs" ON warehouse_logs;
DROP POLICY IF EXISTS "Staging read warehouse_logs" ON warehouse_logs;
DROP POLICY IF EXISTS "Staging allow all audit trail" ON transaction_audit_trail;
DROP POLICY IF EXISTS "Staging read audit trail" ON transaction_audit_trail;

-- 2. Hapus Tabel Baseline Secara Aman (Urutan Child -> Master)
DROP TABLE IF EXISTS transaction_audit_trail CASCADE;
DROP TABLE IF EXISTS warehouse_logs CASCADE;
DROP TABLE IF EXISTS logs CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
