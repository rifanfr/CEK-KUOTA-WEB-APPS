-- =============================================================================
-- STAGING BASELINE VERIFICATION
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Target: Assertion Keberadaan Objek Skema Baseline, Kolom, Constraint, RLS, Grants, & Seed
-- =============================================================================

-- 1. VERIFIKASI KEBERADAAN 4 TABEL UTAMA
SELECT 
  table_name, 
  table_type 
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_name IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY table_name;

-- 2. VERIFIKASI KOLOM DAN TIPE DATA UTAMA
SELECT 
  table_name, 
  column_name, 
  data_type, 
  is_nullable, 
  column_default 
FROM information_schema.columns 
WHERE table_schema = 'public' 
  AND table_name IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY table_name, ordinal_position;

-- 3. VERIFIKASI PRIMARY KEY PADA KEEMPAT TABEL
SELECT 
  tc.table_name, 
  tc.constraint_name, 
  kcu.column_name 
FROM information_schema.table_constraints tc 
JOIN information_schema.key_column_usage kcu 
  ON tc.constraint_name = kcu.constraint_name 
WHERE tc.table_schema = 'public' 
  AND tc.constraint_type = 'PRIMARY KEY' 
  AND tc.table_name IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY tc.table_name;

-- 4. VERIFIKASI CHECK CONSTRAINT INTEGRITAS
SELECT 
  conrelid::regclass AS table_name, 
  conname, 
  pg_get_constraintdef(oid) AS definition 
FROM pg_constraint 
WHERE conname IN (
  'chk_customers_no_kk_format',
  'chk_logs_qty_beras',
  'chk_logs_qty_gas',
  'chk_logs_total',
  'chk_wh_qty_positive',
  'chk_wh_item_valid'
)
ORDER BY table_name, conname;

-- 5. VERIFIKASI INDEKS PERFORMA & KEUNIKAN
SELECT 
  tablename, 
  indexname, 
  indexdef 
FROM pg_indexes 
WHERE tablename IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY tablename, indexname;

-- 6. VERIFIKASI STATUS ROW LEVEL SECURITY (RLS) PADA KEEMPAT TABEL
SELECT 
  relname AS table_name, 
  relrowsecurity AS rls_enabled,
  relforcerowsecurity AS rls_forced
FROM pg_class 
WHERE relname IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY relname;

-- 7. VERIFIKASI HAK AKSES TABEL (TABLE GRANTS) UNTUK ANON & AUTHENTICATED
SELECT 
  grantee, 
  table_name, 
  privilege_type 
FROM information_schema.role_table_grants 
WHERE table_schema = 'public' 
  AND grantee IN ('anon', 'authenticated')
  AND table_name IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY table_name, grantee, privilege_type;

-- 8. VERIFIKASI DEFINISI KEBIJAKAN RLS AKTIF (HANYA SELECT, TIDAK ADA FOR ALL)
SELECT 
  schemaname, 
  tablename, 
  policyname, 
  permissive, 
  roles, 
  cmd, 
  qual, 
  with_check 
FROM pg_policies 
WHERE schemaname = 'public' 
  AND tablename IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
ORDER BY tablename, policyname;

-- 9. BUKTI EVALUASI HAK AKSES ANON (TIDAK BOLEH MEMILIKI INSERT, UPDATE, DELETE)
SELECT 
  'anon' AS role_name,
  t.table_name,
  has_table_privilege('anon', 'public.' || quote_ident(t.table_name), 'SELECT') AS can_select,
  has_table_privilege('anon', 'public.' || quote_ident(t.table_name), 'INSERT') AS can_insert,
  has_table_privilege('anon', 'public.' || quote_ident(t.table_name), 'UPDATE') AS can_update,
  has_table_privilege('anon', 'public.' || quote_ident(t.table_name), 'DELETE') AS can_delete
FROM (VALUES ('customers'), ('logs'), ('warehouse_logs'), ('transaction_audit_trail')) AS t(table_name)
ORDER BY t.table_name;

-- 10. BUKTI transaction_audit_trail TERISOLASI PENUH (ANON & AUTHENTICATED TIDAK BISA BACA / TULIS)
SELECT 
  r.role_name,
  has_table_privilege(r.role_name, 'public.transaction_audit_trail', 'SELECT') AS can_select,
  has_table_privilege(r.role_name, 'public.transaction_audit_trail', 'INSERT') AS can_insert,
  has_table_privilege(r.role_name, 'public.transaction_audit_trail', 'UPDATE') AS can_update,
  has_table_privilege(r.role_name, 'public.transaction_audit_trail', 'DELETE') AS can_delete
FROM (VALUES ('anon'), ('authenticated')) AS r(role_name)
ORDER BY r.role_name;

-- 11. VERIFIKASI SALDO AWAL STOK GUDANG SINTETIS (BERAS = 20, GAS = 20)
SELECT 
  item, 
  COALESCE(SUM(CASE WHEN type = 'INITIAL-STOCK' THEN qty ELSE 0 END), 0) AS initial_stock_qty 
FROM warehouse_logs 
WHERE ref LIKE 'STAGING INITIAL STOCK%'
GROUP BY item 
ORDER BY item;

-- 12. ASSERTION OTOMATIS RUNTIME PRE-CHECK LENGKAP
DO $$
DECLARE
  v_beras_stock INT;
  v_gas_stock   INT;
  v_cust_count  INT;
  v_tbl         RECORD;
  v_pol_all_cnt INT;
BEGIN
  -- 12.1 Assert Stok Awal Beras = 20
  SELECT COALESCE(SUM(qty), 0) INTO v_beras_stock 
  FROM warehouse_logs WHERE item = 'beras' AND type = 'INITIAL-STOCK';
  IF v_beras_stock <> 20 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Stok Beras awal harus 20, ditemukan: %', v_beras_stock;
  END IF;

  -- 12.2 Assert Stok Awal Gas = 20
  SELECT COALESCE(SUM(qty), 0) INTO v_gas_stock 
  FROM warehouse_logs WHERE item = 'gas' AND type = 'INITIAL-STOCK';
  IF v_gas_stock <> 20 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Stok Gas awal harus 20, ditemukan: %', v_gas_stock;
  END IF;

  -- 12.3 Assert Zero Customer Records pada Master
  SELECT count(*) INTO v_cust_count FROM customers;
  IF v_cust_count <> 0 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Tabel customers harus kosong bersih (0 data), ditemukan: %', v_cust_count;
  END IF;

  -- 12.4 Assert Row Level Security (RLS) aktif pada seluruh 4 tabel
  FOR v_tbl IN 
    SELECT c.relname 
    FROM pg_class c 
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' 
      AND c.relname IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
      AND c.relrowsecurity = false
  LOOP
    RAISE EXCEPTION 'ASSERTION_FAILED: RLS tidak aktif pada tabel %', v_tbl.relname;
  END LOOP;

  -- 12.5 Assert role anon TIDAK MEMILIKI hak INSERT, UPDATE, DELETE pada tabel manapun
  FOR v_tbl IN 
    SELECT unnest(ARRAY['customers', 'logs', 'warehouse_logs', 'transaction_audit_trail']) AS t_name
  LOOP
    IF has_table_privilege('anon', 'public.' || quote_ident(v_tbl.t_name), 'INSERT') THEN
      RAISE EXCEPTION 'ASSERTION_FAILED: Role anon tidak boleh memiliki hak INSERT pada %', v_tbl.t_name;
    END IF;
    IF has_table_privilege('anon', 'public.' || quote_ident(v_tbl.t_name), 'UPDATE') THEN
      RAISE EXCEPTION 'ASSERTION_FAILED: Role anon tidak boleh memiliki hak UPDATE pada %', v_tbl.t_name;
    END IF;
    IF has_table_privilege('anon', 'public.' || quote_ident(v_tbl.t_name), 'DELETE') THEN
      RAISE EXCEPTION 'ASSERTION_FAILED: Role anon tidak boleh memiliki hak DELETE pada %', v_tbl.t_name;
    END IF;
  END LOOP;

  -- 12.6 Assert role anon & authenticated TIDAK BISA MEMBACA transaction_audit_trail
  IF has_table_privilege('anon', 'public.transaction_audit_trail', 'SELECT') THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Role anon tidak boleh memiliki hak SELECT pada transaction_audit_trail';
  END IF;
  IF has_table_privilege('authenticated', 'public.transaction_audit_trail', 'SELECT') THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Role authenticated tidak boleh memiliki hak SELECT pada transaction_audit_trail';
  END IF;

  -- 12.7 Assert TIDAK ADA policy FOR ALL yang aktif untuk anon / authenticated
  SELECT count(*) INTO v_pol_all_cnt 
  FROM pg_policies 
  WHERE schemaname = 'public' 
    AND tablename IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail')
    AND cmd = 'ALL';
  IF v_pol_all_cnt <> 0 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Ditemukan % policy dengan cmd ALL (hanya SELECT yang diizinkan)', v_pol_all_cnt;
  END IF;

  RAISE NOTICE 'ASSERTION_PASSED: Seluruh verifikasi baseline skema, RLS, Table Grants, Isolasi Audit Trail, dan saldo stok sintetis 100 persen lolos.';
END $$;
