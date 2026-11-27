-- =============================================================================
-- NON-DESTRUCTIVE ROLLBACK: PHASE 1
-- Hanya mencabut triggers, constraints, dan indexes. Kolom data tetap utuh.
-- =============================================================================

-- 1. Lepaskan Trigger Siklus Hidup Penuh (INSERT) dan Kembalikan ke Versi Lama
DROP TRIGGER IF EXISTS trg_audit_logs_track ON logs;
DROP TRIGGER IF EXISTS trg_audit_wh_track ON warehouse_logs;

CREATE OR REPLACE FUNCTION capture_audit_trail_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO transaction_audit_trail(table_name, action_type, record_id, old_data, changed_by, changed_at)
    VALUES (TG_TABLE_NAME, 'DELETE', OLD.id::TEXT, to_jsonb(OLD), current_user, now());
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO transaction_audit_trail(table_name, action_type, record_id, old_data, new_data, changed_by, changed_at)
    VALUES (TG_TABLE_NAME, 'UPDATE', NEW.id::TEXT, to_jsonb(OLD), to_jsonb(NEW), current_user, now());
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_logs_track
AFTER UPDATE OR DELETE ON logs
FOR EACH ROW EXECUTE FUNCTION capture_audit_trail_trigger();

CREATE TRIGGER trg_audit_wh_track
AFTER UPDATE OR DELETE ON warehouse_logs
FOR EACH ROW EXECUTE FUNCTION capture_audit_trail_trigger();

-- 2. Lepaskan Indeks Unik Idempotensi dan Constraint Status
DROP INDEX IF EXISTS uq_logs_request_id;
ALTER TABLE logs DROP CONSTRAINT IF EXISTS chk_logs_status_valid;

-- 3. Lepaskan Indeks log_id pada warehouse_logs
DROP INDEX IF EXISTS idx_wh_log_id;

-- 4. Lepaskan Indeks Tambahan pada transaction_audit_trail
DROP INDEX IF EXISTS idx_audit_request_id;
DROP INDEX IF EXISTS idx_audit_operator_id;

-- (KOLOM request_id, operator_id, dan status PADA logs SERTA
--  KOLOM log_id PADA warehouse_logs SENGAJA DIBIARKAN UTUH)
