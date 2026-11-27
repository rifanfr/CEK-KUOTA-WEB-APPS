-- =============================================================================
-- STAGING BASELINE SCHEMA (PRE-PHASE-1)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Project: Catat Kuota KK
-- Target: Rekonstruksi Skema Dasar Bersih untuk Supabase Staging
-- =============================================================================

-- 0. EKSTENSI POSTGRESQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- =============================================================================
-- 1. TABEL CUSTOMERS (MASTER DATA KARTU KELUARGA & WARGA)
-- Bukti Sumber:
-- - dispatch-console.html: L4200-L4239 (demoCustomers), L10812-L10825 (custPayload)
-- - supabase_hardening_production.sql: L60-L67 (chk_customers_no_kk_format, uq)
-- =============================================================================
CREATE TABLE IF NOT EXISTS customers (
  no_kk TEXT PRIMARY KEY,
  member_id TEXT NOT NULL,
  nama TEXT NOT NULL,
  provinsi TEXT NOT NULL DEFAULT '',
  kabupaten TEXT NOT NULL DEFAULT '',
  kecamatan TEXT NOT NULL DEFAULT '',
  desa TEXT NOT NULL DEFAULT '',
  detail TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Constraint Format Nomor KK (Tepat 16 digit angka)
ALTER TABLE customers
  DROP CONSTRAINT IF EXISTS chk_customers_no_kk_format;

ALTER TABLE customers
  ADD CONSTRAINT chk_customers_no_kk_format 
  CHECK (no_kk ~ '^[0-9]{16}$');

-- Indeks Performa Pencarian Pelanggan
CREATE INDEX IF NOT EXISTS idx_customers_search_suffix 
ON customers USING btree (member_id, no_kk);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_clean_no_kk 
ON customers(no_kk);

COMMENT ON TABLE customers IS 'Master data Kartu Keluarga penerima manfaat';
COMMENT ON COLUMN customers.no_kk IS 'Nomor Induk Kartu Keluarga 16 digit angka (Primary Key)';
COMMENT ON COLUMN customers.member_id IS 'ID Anggota terformat (misal KK-REG-00001-0001). NOT NULL: wajib terisi untuk seluruh data master pelanggan.';


-- =============================================================================
-- 2. TABEL LOGS (PENCATATAN TRANSAKSI PENGAMBILAN KUOTA)
-- Bukti Sumber:
-- - dispatch-console.html: L4241-L4292 (demoLogs), L10830-L10846 (logsPayload)
-- - supabase_hardening_production.sql: L70-L79 (chk_logs_qty_beras, gas, total)
-- =============================================================================
CREATE TABLE IF NOT EXISTS logs (
  id TEXT PRIMARY KEY,
  date DATE NOT NULL,
  time TEXT NOT NULL DEFAULT '12:00',
  no_kk TEXT NOT NULL,
  nama TEXT NOT NULL,
  member_id TEXT,
  qty_beras INT NOT NULL DEFAULT 0,
  qty_gas INT NOT NULL DEFAULT 0,
  total_pcs INT NOT NULL DEFAULT 0,
  revisi_note TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Constraint Kuantitas Transaksi Kuota
ALTER TABLE logs
  DROP CONSTRAINT IF EXISTS chk_logs_qty_beras,
  DROP CONSTRAINT IF EXISTS chk_logs_qty_gas,
  DROP CONSTRAINT IF EXISTS chk_logs_total;

ALTER TABLE logs 
  ADD CONSTRAINT chk_logs_qty_beras CHECK (qty_beras >= 0 AND qty_beras <= 5),
  ADD CONSTRAINT chk_logs_qty_gas CHECK (qty_gas >= 0 AND qty_gas <= 5),
  ADD CONSTRAINT chk_logs_total CHECK (total_pcs = (qty_beras + qty_gas));

-- Indeks Riwayat Transaksi per KK
CREATE INDEX IF NOT EXISTS idx_logs_nokk_date 
ON logs(no_kk, date DESC);

COMMENT ON TABLE logs IS 'Catatan transaksi kuota sembako warga';
COMMENT ON COLUMN logs.id IS 'ID Transaksi unik (misal LOG-1001 atau LOG-XXXXXXXX)';
COMMENT ON COLUMN logs.member_id IS 'ID Anggota penerima manfaat. Kolom ini dibiarkan nullable hanya demi kompatibilitas data historis; fungsi RPC process_quota_dispense mewajibkan member_id untuk seluruh transaksi baru.';


-- =============================================================================
-- 3. TABEL WAREHOUSE_LOGS (MUTASI STOK FISIK GUDANG)
-- Bukti Sumber:
-- - dispatch-console.html: L4297-L4370 (demoWarehouseLogs), L10849-L10863 (whPayload)
-- - supabase_hardening_production.sql: L81-L87 (chk_wh_qty_positive, item_valid)
-- =============================================================================
CREATE TABLE IF NOT EXISTS warehouse_logs (
  id TEXT PRIMARY KEY,
  date DATE NOT NULL,
  type TEXT NOT NULL,
  item TEXT NOT NULL,
  qty INT NOT NULL,
  ref TEXT NOT NULL DEFAULT '',
  log_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Constraint Kuantitas & Item Valid Gudang
ALTER TABLE warehouse_logs
  DROP CONSTRAINT IF EXISTS chk_wh_qty_positive,
  DROP CONSTRAINT IF EXISTS chk_wh_item_valid;

ALTER TABLE warehouse_logs
  ADD CONSTRAINT chk_wh_qty_positive CHECK (qty > 0),
  ADD CONSTRAINT chk_wh_item_valid CHECK (item IN ('beras', 'gas'));

-- Indeks Lookup Mutasi Gudang
CREATE INDEX IF NOT EXISTS idx_wh_item_type 
ON warehouse_logs(item, type);

COMMENT ON TABLE warehouse_logs IS 'Buku besar mutasi keluar-masuk stok gudang';
COMMENT ON COLUMN warehouse_logs.type IS 'Tipe mutasi: INITIAL-STOCK, GR, GI-WARGA, GI-MANUAL, dll';


-- =============================================================================
-- 4. TABEL TRANSACTION_AUDIT_TRAIL (AUDIT FORENSIK PERUBAHAN DATA)
-- Bukti Sumber:
-- - supabase_hardening_production.sql: L11-L25
-- =============================================================================
CREATE TABLE IF NOT EXISTS transaction_audit_trail (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT NOT NULL,
  action_type TEXT NOT NULL CHECK (action_type IN ('INSERT', 'UPDATE', 'DELETE')),
  record_id TEXT NOT NULL,
  old_data JSONB,
  new_data JSONB,
  changed_by TEXT DEFAULT current_user,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_record_id 
ON transaction_audit_trail(record_id);

CREATE INDEX IF NOT EXISTS idx_audit_table_date 
ON transaction_audit_trail(table_name, changed_at DESC);

COMMENT ON TABLE transaction_audit_trail IS 'Log audit trail penelusuran forensik transaksi. Tidak diakses langsung oleh role anon atau authenticated; penulisan hanya dapat dilakukan melalui fungsi dan trigger database terpercaya (SECURITY DEFINER).';


-- =============================================================================
-- 5. ROW LEVEL SECURITY (RLS) & MINIMUM SAFE STAGING PRIVILEGES / POLICIES
-- =============================================================================
-- Aktifkan RLS pada seluruh tabel
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_audit_trail ENABLE ROW LEVEL SECURITY;

-- 1. Cabut seluruh hak akses tabel dari anon, authenticated, dan PUBLIC terlebih dahulu
REVOKE ALL ON TABLE customers, logs, warehouse_logs, transaction_audit_trail FROM anon, authenticated, PUBLIC;

-- 2. Berikan hak SELECT HANYA pada tabel customers, logs, dan warehouse_logs
GRANT SELECT ON TABLE customers, logs, warehouse_logs TO anon, authenticated;

-- CATATAN KEAMANAN transaction_audit_trail:
-- Tidak ada hak akses (GRANT) yang diberikan kepada role anon maupun authenticated.
-- Tabel transaction_audit_trail hanya dapat ditulis melalui fungsi/trigger terpercaya (SECURITY DEFINER).

-- 3. Kebijakan RLS SELECT-Only untuk role anon dan authenticated
-- Bersihkan kebijakan lama (termasuk kebijakan FOR ALL) jika ada
DROP POLICY IF EXISTS "Staging allow all customers" ON customers;
DROP POLICY IF EXISTS "Staging read customers" ON customers;
CREATE POLICY "Staging read customers" 
ON customers FOR SELECT TO anon, authenticated 
USING (true);

DROP POLICY IF EXISTS "Staging allow all logs" ON logs;
DROP POLICY IF EXISTS "Staging read logs" ON logs;
CREATE POLICY "Staging read logs" 
ON logs FOR SELECT TO anon, authenticated 
USING (true);

DROP POLICY IF EXISTS "Staging allow all warehouse_logs" ON warehouse_logs;
DROP POLICY IF EXISTS "Staging read warehouse_logs" ON warehouse_logs;
CREATE POLICY "Staging read warehouse_logs" 
ON warehouse_logs FOR SELECT TO anon, authenticated 
USING (true);

-- transaction_audit_trail: Pastikan tidak ada policy untuk anon / authenticated
DROP POLICY IF EXISTS "Staging allow all audit trail" ON transaction_audit_trail;
DROP POLICY IF EXISTS "Staging read audit trail" ON transaction_audit_trail;


-- =============================================================================
-- 6. SEED DATA SINTETIS AWAL STOK GUDANG (ZERO CUSTOMER DATA)
-- Tanggal: 2026-11-23
-- Beras: 20 sak
-- Gas: 20 tabung
-- =============================================================================
INSERT INTO warehouse_logs (id, date, type, item, qty, ref, log_id, created_at)
VALUES 
  ('WH-INIT-STG-BERAS', '2026-11-23', 'INITIAL-STOCK', 'beras', 20, 'STAGING INITIAL STOCK BERAS', NULL, now()),
  ('WH-INIT-STG-GAS',   '2026-11-23', 'INITIAL-STOCK', 'gas',   20, 'STAGING INITIAL STOCK GAS',   NULL, now())
ON CONFLICT (id) DO NOTHING;
