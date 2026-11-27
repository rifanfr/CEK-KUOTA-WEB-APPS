-- =============================================================================
-- FINAL MIGRATION PACKAGE: PHASE 1 (DATABASE FOUNDATION)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Idempotensi, Status Transaksi Aman, & Full Lifecycle Audit Trail
-- =============================================================================

-- 1. PERLUAS STRUKTUR TABEL AUDIT TRAIL EKSISTING
-- Menambahkan kolom korelasi tanpa membuat ulang tabel
ALTER TABLE transaction_audit_trail 
  ADD COLUMN IF NOT EXISTS request_id TEXT,
  ADD COLUMN IF NOT EXISTS operator_id TEXT;

-- Indeks korelasi audit trail untuk penelusuran forensik
CREATE INDEX IF NOT EXISTS idx_audit_record_id ON transaction_audit_trail(record_id);
CREATE INDEX IF NOT EXISTS idx_audit_request_id ON transaction_audit_trail(request_id) WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_operator_id ON transaction_audit_trail(operator_id) WHERE operator_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_table_date ON transaction_audit_trail(table_name, changed_at DESC);


-- 2. TRIGGER FUNCTION AUDIT (search_path = public, ZERO EXCEPTION BLOCKS, FULL LIFECYCLE)
CREATE OR REPLACE FUNCTION capture_audit_trail_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req_id TEXT := NULL;
  v_op_id  TEXT := NULL;
  v_actor  TEXT := NULL;
BEGIN
  -- Ekstrak request_id dan operator_id secara deterministik untuk tabel logs
  IF TG_TABLE_NAME = 'logs' THEN
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
      v_req_id := NEW.request_id;
      v_op_id  := NEW.operator_id;
    ELSIF TG_OP = 'DELETE' THEN
      v_req_id := OLD.request_id;
      v_op_id  := OLD.operator_id;
    END IF;
  END IF;

  -- Identitas operator riil: operator_id payload -> JWT claim sub -> current_user
  v_actor := COALESCE(
    v_op_id,
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    current_user
  );

  IF TG_OP = 'INSERT' THEN
    INSERT INTO transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'INSERT', NEW.id::TEXT, v_req_id, v_op_id, to_jsonb(NEW), v_actor, now()
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'DELETE', OLD.id::TEXT, v_req_id, v_op_id, to_jsonb(OLD), v_actor, now()
    );
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'UPDATE', NEW.id::TEXT, v_req_id, v_op_id, to_jsonb(OLD), to_jsonb(NEW), v_actor, now()
    );
    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$$;

-- Pasang trigger pada tabel logs (INSERT + UPDATE + DELETE)
DROP TRIGGER IF EXISTS trg_audit_logs_track ON logs;
CREATE TRIGGER trg_audit_logs_track
AFTER INSERT OR UPDATE OR DELETE ON logs
FOR EACH ROW EXECUTE FUNCTION capture_audit_trail_trigger();

-- Pasang trigger pada tabel warehouse_logs (INSERT + UPDATE + DELETE)
DROP TRIGGER IF EXISTS trg_audit_wh_track ON warehouse_logs;
CREATE TRIGGER trg_audit_wh_track
AFTER INSERT OR UPDATE OR DELETE ON warehouse_logs
FOR EACH ROW EXECUTE FUNCTION capture_audit_trail_trigger();


-- 3. FONDASI IDEMPOTENSI, OPERATOR, & STATUS PADA TABEL logs (SAFE BACKFILL SEQUENCE)
-- Langkah 3a: Tambah kolom baru (nullable)
ALTER TABLE logs 
  ADD COLUMN IF NOT EXISTS request_id TEXT,
  ADD COLUMN IF NOT EXISTS operator_id TEXT,
  ADD COLUMN IF NOT EXISTS status TEXT;

-- Langkah 3b: Backfill data historis yang sudah ada
UPDATE logs 
SET status = 'COMPLETED' 
WHERE status IS NULL;

-- Langkah 3c: Tetapkan nilai default untuk baris baru
ALTER TABLE logs 
  ALTER COLUMN status SET DEFAULT 'COMPLETED';

-- Langkah 3d: Pasang constraint NOT NULL dan CHECK validasi status
ALTER TABLE logs 
  ALTER COLUMN status SET NOT NULL;

ALTER TABLE logs 
  DROP CONSTRAINT IF EXISTS chk_logs_status_valid;

ALTER TABLE logs 
  ADD CONSTRAINT chk_logs_status_valid 
  CHECK (status IN ('COMPLETED', 'CANCELLED', 'REFUNDED'));

-- Langkah 3e: Indeks unik idempotensi parsial (hanya berlaku jika request_id terisi)
CREATE UNIQUE INDEX IF NOT EXISTS uq_logs_request_id 
ON logs(request_id) 
WHERE request_id IS NOT NULL;


-- 4. PERSIAPAN RELASI LOG GUDANG (INDEX SAJA, TANPA FOREIGN KEY DAHULU)
ALTER TABLE warehouse_logs 
  ADD COLUMN IF NOT EXISTS log_id TEXT;

CREATE INDEX IF NOT EXISTS idx_wh_log_id 
ON warehouse_logs(log_id) 
WHERE log_id IS NOT NULL;
