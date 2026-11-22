-- =============================================================================
-- CEKKUOTA-KK: DATABASE HARDENING & CONCURRENCY CONSTRAINTS (STEP 2 AUDIT)
-- Jalankan skrip ini pada Supabase Dashboard -> SQL Editor
-- =============================================================================

-- 1. CONSTRAINT INTEGRITAS INPUT NOMOR KK (Tepat 16 Digit Angka)
ALTER TABLE customers
  DROP CONSTRAINT IF EXISTS chk_customers_no_kk_format;

ALTER TABLE customers
  ADD CONSTRAINT chk_customers_no_kk_format CHECK (no_kk ~ '^[0-9]{16}$');

-- Unique Index untuk mencegah duplikasi No. KK
CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_clean_no_kk ON customers(no_kk);

-- 2. CONSTRAINT VALIDASI TRANSAKSI LOGS (Nilai Positif & Batas Maksimal)
ALTER TABLE logs
  DROP CONSTRAINT IF EXISTS chk_logs_qty_beras,
  DROP CONSTRAINT IF EXISTS chk_logs_qty_gas,
  DROP CONSTRAINT IF EXISTS chk_logs_total;

ALTER TABLE logs 
  ADD CONSTRAINT chk_logs_qty_beras CHECK (qty_beras >= 0 AND qty_beras <= 5),
  ADD CONSTRAINT chk_logs_qty_gas CHECK (qty_gas >= 0 AND qty_gas <= 5),
  ADD CONSTRAINT chk_logs_total CHECK (total_pcs = (qty_beras + qty_gas));

-- 3. CONSTRAINT MUTASI GUDANG (Stok Positif & Tipe Valid)
ALTER TABLE warehouse_logs
  DROP CONSTRAINT IF EXISTS chk_wh_qty_positive,
  DROP CONSTRAINT IF EXISTS chk_wh_item_valid;

ALTER TABLE warehouse_logs
  ADD CONSTRAINT chk_wh_qty_positive CHECK (qty > 0),
  ADD CONSTRAINT chk_wh_item_valid CHECK (item IN ('beras', 'gas'));

-- 4. ROW-LEVEL CONCURRENCY LOCK & TRIGGER VALIDASI KUOTA MAKSIMUM 5 PCS
CREATE OR REPLACE FUNCTION validate_quota_limit_trigger()
RETURNS TRIGGER AS $$
DECLARE
  v_existing_beras INT;
  v_existing_gas INT;
BEGIN
  -- Kunci baris pelanggan untuk serialisasi transaksi serentak
  PERFORM 1 FROM customers WHERE no_kk = NEW.no_kk FOR UPDATE;

  -- Hitung akumulasi pemakaian dalam siklus 30 hari berjalan
  SELECT 
    COALESCE(SUM(qty_beras), 0),
    COALESCE(SUM(qty_gas), 0)
  INTO v_existing_beras, v_existing_gas
  FROM logs
  WHERE no_kk = NEW.no_kk
    AND date >= (NEW.date - INTERVAL '30 days')
    AND id <> NEW.id;

  -- Blokir jika kuota 5 pcs tertembus
  IF (v_existing_beras + NEW.qty_beras) > 5 THEN
    RAISE EXCEPTION 'Pelanggaran Kuota: Sisa kuota Beras tidak mencukupi (Total: % > 5)', (v_existing_beras + NEW.qty_beras);
  END IF;

  IF (v_existing_gas + NEW.qty_gas) > 5 THEN
    RAISE EXCEPTION 'Pelanggaran Kuota: Sisa kuota Gas tidak mencukupi (Total: % > 5)', (v_existing_gas + NEW.qty_gas);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_quota_limit ON logs;
CREATE TRIGGER trg_check_quota_limit
BEFORE INSERT ON logs
FOR EACH ROW EXECUTE FUNCTION validate_quota_limit_trigger();

-- 5. INDEXING UNTUK QUERY PERFORMA TINGGI (< 2 ms)
CREATE INDEX IF NOT EXISTS idx_logs_nokk_date ON logs(no_kk, date DESC);
CREATE INDEX IF NOT EXISTS idx_wh_item_type ON warehouse_logs(item, type);
CREATE INDEX IF NOT EXISTS idx_customers_search_suffix ON customers USING btree (member_id, no_kk);
